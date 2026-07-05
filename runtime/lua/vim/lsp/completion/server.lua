--- Buffer-word completion backend for |vim.lsp.completion|.
---
--- An in-process LSP server answering `textDocument/completion` by scanning
--- buffers for keyword matches. Replaces the synchronous buffer collectors in
--- insexpand.c: the scan runs on a coroutine and yields between batches, so a
--- large buffer doesn't block input or redraw.
---
--- Collection only. Config and the enable/attach entry points live in
--- completion.lua. Whether to restrict the scan to the current buffer is passed
--- via the request context (`params.context.local_only`), set by the caller.
---
--- A "word" is a run of 'iskeyword' chars, matched with `\k` -- the same
--- definition insexpand.c and vim.lsp.completion use. Matches are filtered by
--- the typed prefix; the client does the fuzzy ranking.

local async = require('vim._async')

local api = vim.api
local uv = vim.uv
local protocol = vim.lsp.protocol
local CompletionItemKind = protocol.CompletionItemKind
local log = vim.lsp.log

-- Lines per coroutine slice.

local SCAN_BATCH = 1500
-- Item cap. Past this, truncate and mark the list incomplete.
local MAX_ITEMS = 1000

--- Effective 'completeopt' for `bufnr`, mirroring get_cot_flags(): the option
--- is global-local, so the buffer-local value applies when set and the global
--- value otherwise. Reading only the {buf=} slot misses a plain :set (the
--- local slot is empty then -- the Test_nearest_cpt_option run logged cot=""
--- while the global held "menuone,noselect,longest"), and reading only
--- vim.opt (global) misses a :setlocal.
--- @param bufnr integer  buffer handle; 0 for the current buffer
--- @return string
local function effective_cot(bufnr)
  local cot = vim.api.nvim_get_option_value('completeopt', { buf = bufnr })
  if cot == '' then
    cot = vim.api.nvim_get_option_value('completeopt', { scope = 'global' })
  end
  return cot
end

--- Whether the effective 'completeopt' of `bufnr` contains exactly `flag`.
--- Exact comma-entry matching, not substring find(): "menu" must not match
--- "menuone".
--- @param bufnr integer  buffer handle; 0 for the current buffer
--- @param flag string
--- @return boolean
local function cot_has(bufnr, flag)
  for f in vim.gsplit(effective_cot(bufnr), ',', { plain = true }) do
    if f == flag then
      return true
    end
  end
  return false
end

--- Read a whole file asynchronously via libuv, yielding the coroutine while the
--- I/O is in flight so the main loop stays responsive (unlike io.open/read,
--- which block on the syscall). Returns the file contents, or nil on any error.
--- NOTE: the raw uv callbacks resume the coroutine in a fast event context;
--- callers must go through read_file_async below, which hops back to a safe
--- context before returning.
--- @async
--- @param path string
--- @return string?
local function read_file_uv(path)
  local oerr, fd = async.await(4, uv.fs_open, path, 'r', 438)
  if oerr or not fd then
    log.warn(
      string.format('BUILTIN read_file_async: open FAIL path=%q oerr=%s', path, tostring(oerr))
    )
    return nil
  end
  local serr, stat = async.await(2, uv.fs_fstat, fd)
  if serr or not stat then
    log.warn(
      string.format('BUILTIN read_file_async: fstat FAIL path=%q serr=%s', path, tostring(serr))
    )
    async.await(2, uv.fs_close, fd)
    return nil
  end
  local data = nil --- @type string?
  if stat.size > 0 then
    local rerr, chunk = async.await(4, uv.fs_read, fd, stat.size, 0)
    if not rerr then
      data = chunk
    else
      log.warn(
        string.format(
          'BUILTIN read_file_async: read FAIL path=%q size=%d rerr=%s',
          path,
          stat.size,
          tostring(rerr)
        )
      )
    end
  else
    data = ''
  end
  async.await(2, uv.fs_close, fd)
  log.warn(
    string.format(
      'BUILTIN read_file_async: DONE path=%q size=%d data_len=%s',
      path,
      stat.size,
      data and #data or 'nil'
    )
  )
  return data
end

--- Threshold below which a file is read synchronously (see read_file_async).
local SYNC_READ_MAX = 64 * 1024

--- Read a small file synchronously, with blocking uv.fs_* calls (no callback =
--- no coroutine yield). Returns the contents, false when the file is too large
--- to read this way, or nil on any error / non-regular file.
--- @param path string
--- @return string|false|nil
local function read_file_sync(path)
  local fd = uv.fs_open(path, 'r', 438)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  if not stat or stat.type ~= 'file' then
    uv.fs_close(fd)
    return nil
  end
  if stat.size > SYNC_READ_MAX then
    uv.fs_close(fd)
    return false
  end
  local data = '' --- @type string?
  if stat.size > 0 then
    data = uv.fs_read(fd, stat.size, 0) or nil
  end
  uv.fs_close(fd)
  return data
end

--- read_file_uv, then hop back onto the main event queue before returning:
--- the raw libuv callbacks that resume the reading coroutine run in a fast
--- event context, where most API functions -- and the completion response
--- path delivered from cmd()'s on_finish -- are forbidden (E5560). After this
--- await the continuation runs from vim.schedule, i.e. a safe context, no
--- matter which uv callback resumed the read. Same idiom as the SCAN_BATCH
--- slicing yields.
---
--- Small files (<= SYNC_READ_MAX) are read synchronously first: a blocking
--- uv.fs_read of a few KB is a microsecond-scale syscall, and forcing it async
--- only splits that microsecond of work across two event-loop turns, which
--- breaks keystroke sequencing (the next key is consumed before the response
--- lands) for no user-visible gain. Asynchronous collection is kept for large
--- scans, where it actually keeps input responsive. The synchronous path also
--- makes the whole trigger -> collect -> apply chain run in the firing stack,
--- so a manual completion (and packed-typeahead tests) sees a finished session
--- immediately. Only genuinely large files fall back to the yielding reader.
--- @async
--- @param path string
--- @return string?
local function read_file_async(path)
  local sync = read_file_sync(path)
  if sync ~= false then
    -- Hit (string) or hard error/non-file (nil): no async needed. Return
    -- directly; the caller is already on a safe (coroutine) context.
    return sync
  end
  -- Large file: fall back to the fully asynchronous reader + safe-context hop.
  local data = read_file_uv(path)
  async.await(1, vim.schedule)
  return data
end

--- Expand the comma-separated 'dictionary'/'thesaurus' option into real file
--- paths (each entry may be a glob).
--- @param opt string
--- @return string[]
local function option_files(opt)
  local files = {} --- @type string[]
  for entry in vim.gsplit(opt, ',', { plain = true }) do
    if entry ~= '' then
      local ok, globbed = pcall(vim.fn.glob, entry, false, true)
      if ok and type(globbed) == 'table' then
        for _, f in ipairs(globbed) do
          files[#files + 1] = f
        end
      end
    end
  end
  return files
end

local M = {}

--- Completion context with the in-process hints set by the caller.
--- @class vim.lsp.completion._server.Context : lsp.CompletionContext
--- @field local_only? boolean  restrict the scan to the current buffer (|i_CTRL-X_CTRL-N|); nil/false also scans other loaded, listed buffers (|i_CTRL-N|)
--- @field backward? boolean  the trigger key searches backward (e.g. CTRL-P, CTRL-X CTRL-L); affects the initial selection for keyword and whole-line
--- @field mode? string  completion source: nil/"keyword" scans buffers; "files" expands filenames (|i_CTRL-X_CTRL-F|); "lines" matches whole lines (|i_CTRL-X_CTRL-L|); "dictionary" reads 'dictionary' files (|i_CTRL-X_CTRL-K|); "thesaurus" reads 'thesaurus' files (|i_CTRL-X_CTRL-T|); "tags" reads 'tags' files (|i_CTRL-X_CTRL-]|); "cmdline" expands Ex commands (|i_CTRL-X_CTRL-V|); "register" offers words from registers (|i_CTRL-X_CTRL-R|)
--- @field startcol? integer  0-based byte column where the base starts, precomputed by the C routing gate for sources whose boundary lives in C engines: currently "cmdline" (set_cmd_context()'s xp_pattern offset)

--- Buffers to scan: current buffer first, then -- unless restricted to the
--- current buffer -- the other loaded, listed buffers.
--- @param cur_buf integer
--- @param local_only boolean?  true for |i_CTRL-X_CTRL-N| (current buffer only)
--- @return integer[]
--- Select the buffers to scan based on the 'complete' (cpt) option's buffer
--- flags, mirroring ins_compl_next_buf():
---   '.'  the current buffer
---   'w'  buffers shown in other windows
---   'b'  listed buffers that are loaded
---   'u'  listed buffers that are not loaded
---   'U'  unlisted buffers
--- Buffers are collected in the order the flags appear in cpt, de-duplicated.
--- A `local_only` trigger (|i_CTRL-X_CTRL-N|) ignores cpt and scans only the
--- current buffer. When cpt has no buffer flag at all, nothing is scanned here.
--- @param cur_buf integer  current buffer handle
--- @param local_only boolean?  true restricts to the current buffer
--- @return integer[]
--- Parse 'complete' into source entries: flag, optional argument
--- (k{file}/s{file}/F{func}) and optional "^count" match limit. "kspell" is
--- its own flag. Unknown or not-yet-implemented flags are returned as-is so
--- callers skip them explicitly -- there is no native fallback to defer to.
--- @param cpt string
--- @return { kind: string, arg: string?, max: integer? }[]
local function parse_cpt(cpt)
  local out = {} --- @type { kind: string, arg: string?, max: integer? }[]
  for entry in vim.gsplit(cpt, ',', { plain = true }) do
    if entry ~= '' then
      local body, cnt = entry:match('^(.-)%^(%d+)$')
      body = body or entry
      local kind, arg
      if body == 'kspell' then
        kind = 'kspell'
      else
        kind = body:sub(1, 1)
        arg = body:sub(2)
        if arg == '' then
          arg = nil
        end
      end
      out[#out + 1] = { kind = kind, arg = arg, max = cnt and tonumber(cnt) or nil }
    end
  end
  return out
end

--- Buffers selected by one 'complete' buffer flag, in the order native's
--- ins_compl_next_buf() would visit them; nil for non-buffer flags. The
--- current buffer is only selected by '.', mirroring native (the other flags
--- exclude curbuf).
--- @param kind string  cpt flag ('.', 'w', 'b', 'u', 'U', ...)
--- @param cur_buf integer
--- @return integer[]?
local function buffers_for_flag(kind, cur_buf)
  if kind == '.' then
    return { cur_buf }
  elseif kind == 'w' then
    local bufs = {} --- @type integer[]
    local added = {} --- @type table<integer, true>
    for _, win in ipairs(api.nvim_list_wins()) do
      local b = api.nvim_win_get_buf(win)
      if b ~= cur_buf and not added[b] then
        added[b] = true
        bufs[#bufs + 1] = b
      end
    end
    return bufs
  elseif kind == 'b' or kind == 'u' or kind == 'U' then
    local bufs = {} --- @type integer[]
    for _, b in ipairs(api.nvim_list_bufs()) do
      if b ~= cur_buf then
        local listed = vim.bo[b].buflisted
        local loaded = api.nvim_buf_is_loaded(b)
        local match = (kind == 'b' and listed and loaded)
          or (kind == 'u' and listed and not loaded)
          or (kind == 'U' and not listed)
        if match then
          bufs[#bufs + 1] = b
        end
      end
    end
    return bufs
  end
  return nil
end

local function target_buffers(cur_buf, local_only)
  if local_only then
    return { cur_buf }
  end

  local bufs = {} --- @type integer[]
  local added = {} --- @type table<integer, true>
  for _, e in ipairs(parse_cpt(vim.bo[cur_buf].complete)) do
    for _, b in ipairs(buffers_for_flag(e.kind, cur_buf) or {}) do
      if not added[b] then
        added[b] = true
        bufs[#bufs + 1] = b
      end
    end
  end

  return bufs
end

--- Keyword prefix before the cursor.
--- @param line string
--- @param col integer  0-based byte column
--- @return string
local function keyword_prefix(line, col)
  return vim.fn.matchstr(line:sub(1, col), [[\k*$]])
end

--- Filename prefix before the cursor: the run of 'isfname' characters ending
--- at the cursor. This is the path fragment the user has typed so far (e.g.
--- "src/ma" or "~/.config/nv"). Mirrors get_filename_compl_info()'s backward
--- scan over vim_isfilec(); the precise platform edge cases (MS-Windows drive
--- letters) are not reproduced here.
--- @param line string
--- @param col integer  0-based byte column
--- @return string
local function filename_prefix(line, col)
  -- 'isfname' defines filename characters; \f matches them. Grab the trailing
  -- run of \f before the cursor.
  return vim.fn.matchstr(line:sub(1, col), [[\f*$]])
end

--- Collect filename completions for the path fragment `prefix` by reusing
--- Vim's own file expansion (getcompletion(..., 'file') calls expand_wildcards
--- under the hood), so glob rules, '~' expansion and path handling stay
--- identical to the native CTRL-X CTRL-F path.
---
--- Each item carries a `textEdit` whose range covers the part of the fragment
--- that should be replaced; the full path -- e.g. "src/main.c" for typed
--- "src/ma" -- goes in newText. The LSP boundary logic in completion.lua then
--- uses the filename boundary rather than the keyword boundary.
---
--- Two modes:
---   * Prefix (default): glob `prefix*`, replace the whole fragment. The
---     client filters by prefix against the full path.
---   * Fuzzy (cot=fuzzy): glob the *directory* of the fragment so the client
---     has every file to fuzzy-rank, set filterText to the bare filename and
---     point the textEdit at the filename part, so the client's prefix is the
---     typed filename (e.g. ".na") and it fuzzy-matches the names. This mirrors
---     get_next_filename_completion()'s split of the leader into dir + name.
--- @param prefix string  path fragment typed so far (over 'isfname' chars)
--- @param lnum integer  0-based cursor line (LSP)
--- @param start_char integer  utf-16 column where the fragment starts
--- @param end_char integer  utf-16 column at the cursor
--- @return lsp.CompletionItem[]
--- @return boolean truncated
local function collect_files(prefix, lnum, start_char, end_char)
  -- In-process request: driven from the current buffer (see resolve_position),
  -- so buf 0 gives the right global-local 'completeopt'.
  local fuzzy = cot_has(0, 'fuzzy')

  -- Split off the directory part (everything up to and including the last
  -- separator). dir is "" when the fragment has no separator; name is the typed
  -- filename part after it.
  local dir = prefix:match('^.*[/\\]') or ''
  local name = prefix:sub(#dir + 1)

  -- List the whole directory (including hidden files) when there is no typed
  -- filename to anchor a prefix glob, or when fuzzy matching is on (the typed
  -- name may fuzzy-match any file, hidden ones included). Otherwise glob the
  -- typed name as a prefix, where a leading-dot file simply won't match unless
  -- the user typed the dot.
  local list_dir = fuzzy or name == ''

  local matches --- @type string[]
  if list_dir then
    -- getcompletion's "*" does not match a leading dot, so also glob "<dir>.*"
    -- and merge to include hidden files. Drop the "." and ".." entries that
    -- ".*" pulls in.
    local seen = {} --- @type table<string, true>
    matches = {}
    for _, p in ipairs({ dir .. '*', dir .. '.*' }) do
      local ok, ms = pcall(vim.fn.getcompletion, p, 'file')
      if ok and type(ms) == 'table' then
        for _, m in ipairs(ms) do
          local base = m:match('([^/\\]*)[/\\]?$')
          if base ~= '.' and base ~= '..' and not seen[m] then
            seen[m] = true
            matches[#matches + 1] = m
          end
        end
      end
    end
  else
    -- Prefix mode globs the typed name directly.
    local ok, ms = pcall(vim.fn.getcompletion, prefix .. '*', 'file')
    if not ok or type(ms) ~= 'table' then
      return {}, false
    end
    matches = ms
  end

  -- When listing a directory the replaced range starts at the filename (after
  -- dir), so the client's prefix is the bare typed name and matches against the
  -- filename filterText.
  local edit_start = start_char
  if list_dir and #dir > 0 then
    edit_start = start_char + vim.str_utfindex(dir, 'utf-16', #dir, false)
  end
  local range = {
    start = { line = lnum, character = edit_start },
    ['end'] = { line = lnum, character = end_char },
  }

  local items = {} --- @type lsp.CompletionItem[]
  local n = 0
  for _, m in ipairs(matches) do
    n = n + 1
    -- When listing a directory, match/insert the filename part. getcompletion
    -- may return a directory with a trailing separator (e.g. "src/sub/"); keep
    -- that separator on the name so the inserted text and the entry stay valid.
    local fname = m
    if list_dir then
      fname = m:match('([^/\\]*[/\\]?)$')
      if fname == nil or fname == '' then
        fname = m
      end
    end
    items[n] = {
      label = fname,
      kind = CompletionItemKind.File,
      sortText = ('%08d'):format(n),
      filterText = fname,
      textEdit = { range = range, newText = fname },
    }
    if n >= MAX_ITEMS then
      return items, true
    end
  end
  return items, false
end

--- Whole-line prefix: the current line from its first non-blank character up to
--- the cursor, plus the byte length of the leading indent. Mirrors
--- get_wholeline_compl_info(), which sets compl_col to getwhitecols(line) so the
--- match ignores indentation.
--- @param line string
--- @param col integer  0-based byte column of the cursor
--- @return string leader  text from first non-blank to cursor
--- @return integer indent  byte length of the leading whitespace
local function line_prefix(line, col)
  local indent = #(line:match('^%s*') or '')
  if indent > col then
    -- Cursor sits inside the indent: empty leader, anchor at the cursor.
    return '', col
  end
  return line:sub(indent + 1, col), indent
end

--- Collect whole-line completions (CTRL-X CTRL-L): every line in the scanned
--- buffers whose content after its own indentation starts with `leader`. The
--- inserted text is that de-indented line, replacing from the current line's
--- indent to the cursor, mirroring search_for_exact_line() + the "^\s*\zs"
--- pattern used natively.
--- @async
--- @param leader string  de-indented current-line prefix
--- @param indent integer  byte length of the current line's indent (= start col)
--- @param bufnr integer  current buffer
--- @param local_only boolean?  restrict to the current buffer
--- @param lnum integer  0-based cursor line (LSP)
--- @param end_char integer  utf-16 column at the cursor
--- @return lsp.CompletionItem[]
--- @return boolean truncated
local function collect_lines(leader, indent, bufnr, local_only, lnum, end_char, backward)
  -- Case handling mirrors insexpand.c (ignorecase + smartcase override).
  local fuzzy = cot_has(bufnr, 'fuzzy')
  local icase = vim.o.ignorecase
  if icase and vim.o.smartcase and leader:match('%u') then
    icase = false
  end
  local cmp_leader = icase and leader:lower() or leader
  local llen = #leader

  -- The replaced range starts after the current line's indent (compl_col) so
  -- inserting a de-indented line keeps the existing indentation.
  local cur = api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1] or ''
  local start_char = vim.str_utfindex(cur, 'utf-16', math.min(indent, #cur), false)
  local range = {
    start = { line = lnum, character = start_char },
    ['end'] = { line = lnum, character = end_char },
  }

  local seen = {} --- @type table<string, true>
  local items = {} --- @type lsp.CompletionItem[]
  local n = 0
  local truncated_lines = false

  -- Test one raw line: strip its indent, filter by leader, and append an item.
  -- Returns true if the item cap was hit (caller should stop).
  local function consider(raw)
    -- Strip the line's own indentation, matching getwhitecols() on each
    -- candidate line.
    local text = raw:match('^%s*(.*)$') or raw
    if text == '' or seen[text] or text == leader then
      return false
    end
    -- Fuzzy mode hands every line to the client, which ranks them by the typed
    -- leader; prefix mode filters here. (search_for_fuzzy_match vs
    -- search_for_exact_line in get_next_default_completion.)
    local keep = fuzzy or leader == ''
    if not keep then
      local head = text:sub(1, llen)
      if icase then
        head = head:lower()
      end
      keep = head == cmp_leader
    end
    if not keep then
      return false
    end
    seen[text] = true
    n = n + 1
    items[n] = {
      label = text,
      kind = CompletionItemKind.Text,
      sortText = ('%08d'):format(n),
      filterText = text,
      textEdit = { range = range, newText = text },
    }
    if n >= MAX_ITEMS then
      truncated_lines = true
      return true
    end
    return false
  end

  local bufs = target_buffers(bufnr, local_only)
  do
    local info = {}
    for _, b in ipairs(bufs) do
      info[#info + 1] = string.format(
        'buf=%d listed=%s loaded=%s name=%q',
        b,
        tostring(vim.bo[b].buflisted),
        tostring(api.nvim_buf_is_loaded(b)),
        api.nvim_buf_get_name(b)
      )
    end
    log.warn(
      string.format(
        'BUILTIN collect_lines: cpt=%q cur=%d bufs=[%s]',
        vim.bo[bufnr].complete,
        bufnr,
        table.concat(info, ' | ')
      )
    )
  end
  for _, buf in ipairs(bufs) do
    if api.nvim_buf_is_loaded(buf) then
      -- Native search order: the current buffer starts at the cursor and
      -- wraps ('wrapscan' is forced there); a BACKWARD search (CTRL-X CTRL-L
      -- pre-inserts via CTRL-P) walks the same ranges bottom-up, so the first
      -- line considered is the nearest one above the cursor. The sortText
      -- reversal below then puts that first find last, where the initial
      -- CTRL-P selection lands (ins_compl_add() links BACKWARD finds before
      -- the current match, so the native list reads top-down while the shown
      -- match starts at the first find). Other buffers are scanned whole in
      -- the search direction. The cursor line itself is never a candidate.
      local line_count = api.nvim_buf_line_count(buf)
      local cur_lnum = lnum + 1 -- 1-based cursor line
      --- @type {[1]: integer, [2]: integer, [3]: integer}[] from, to, step
      local ranges
      if buf == bufnr then
        if backward then
          ranges = { { cur_lnum - 1, 1, -1 }, { line_count, cur_lnum + 1, -1 } }
        else
          ranges = { { cur_lnum + 1, line_count, 1 }, { 1, cur_lnum - 1, 1 } }
        end
      elseif backward then
        ranges = { { line_count, 1, -1 } }
      else
        ranges = { { 1, line_count, 1 } }
      end
      local scanned = 0
      local stop_scan = false
      for _, r in ipairs(ranges) do
        for l = r[1], r[2], r[3] do
          local raw = api.nvim_buf_get_lines(buf, l - 1, l, false)[1] or ''
          if consider(raw) then
            stop_scan = true
            break
          end
          scanned = scanned + 1
          if scanned % SCAN_BATCH == 0 then
            async.await(1, vim.schedule)
          end
        end
        if stop_scan then
          break
        end
      end
    else
      -- An unloaded buffer (selected by the cpt 'u'/'U' flag) has no in-memory
      -- lines; native scans it from its file like a dictionary, but skips
      -- buffers without a real filename (b_fname == NULL). A buffer with an
      -- empty name resolves to a directory path here, so skip anything that
      -- isn't a readable regular file to avoid an EISDIR read.
      local fname = api.nvim_buf_get_name(buf)
      log.warn(string.format('BUILTIN collect_lines unloaded branch: buf=%d fname=%q', buf, fname))
      local stat = fname ~= '' and uv.fs_stat(fname) or nil
      if stat and stat.type == 'file' then
        local data = read_file_async(fname)
        log.warn(
          string.format('BUILTIN collect_lines unloaded read: data_len=%s', data and #data or 'nil')
        )
        if data then
          for raw in (data .. '\n'):gmatch('(.-)\n') do
            if consider(raw) then
              break
            end
          end
        end
      end
    end
  end

  -- The client sorts candidates by sortText, so ordering must be conveyed there,
  -- not by list position. Items are collected top-to-bottom with ascending
  -- sortText. On a backward trigger (CTRL-X CTRL-L, which pre-inserts via
  -- CTRL-P), the initial selection is the cyclic list's tail; whole-line expects
  -- that to be the nearest match above, i.e. the first line found scanning down.
  -- Reversing sortText puts the first-found item last after the client sorts.
  if backward then
    local total = #items
    for idx = 1, total do
      items[idx].sortText = ('%08d'):format(total - idx + 1)
    end
  end
  log.warn(
    string.format(
      'BUILTIN collect_lines RESULT: leader=%q backward=%s n=%d labels=%s newTexts=%s sortTexts=%s',
      leader,
      tostring(backward),
      #items,
      vim.inspect(
        vim.tbl_map(function(it)
          return it.label
        end, items),
        { newline = '', indent = '' }
      ),
      vim.inspect(
        vim.tbl_map(function(it)
          return it.textEdit and it.textEdit.newText
        end, items),
        { newline = '', indent = '' }
      ),
      vim.inspect(
        vim.tbl_map(function(it)
          return it.sortText
        end, items),
        { newline = '', indent = '' }
      )
    )
  )
  return items, truncated_lines
end

--- Collect dictionary completions (CTRL-X CTRL-K): words from the files listed
--- in 'dictionary' that start with `prefix`. 'dictionary' is a comma-separated
--- list of files/globs; each is read line by line and every \k word is checked.
--- Mirrors ins_compl_dictionaries(): the leader is the keyword before the cursor
--- (CTRL_X_WANT_IDENT uses get_normal_compl_info, same as keyword completion).
--- @async
--- @param prefix string  keyword prefix typed so far
--- @param lnum integer  0-based cursor line (LSP)
--- @param start_char integer  utf-16 column where the prefix starts
--- @param end_char integer  utf-16 column at the cursor
--- @return lsp.CompletionItem[]
--- @return boolean truncated
local function collect_dict(prefix, lnum, start_char, end_char, files)
  -- An empty 'dictionary' has nothing to scan (native code also bails, falling
  -- back to spell only when that is wired up, which it is not here).
  local dict_opt = vim.bo.dictionary
  if dict_opt == nil or dict_opt == '' then
    dict_opt = vim.o.dictionary
  end
  if not files and (dict_opt == nil or dict_opt == '') then
    return {}, false
  end

  local fuzzy = cot_has(0, 'fuzzy')
  local icase = vim.o.ignorecase
  if icase and vim.o.smartcase and prefix:match('%u') then
    icase = false
  end
  local cmp_prefix = icase and prefix:lower() or prefix
  local plen = #prefix

  local range = {
    start = { line = lnum, character = start_char },
    ['end'] = { line = lnum, character = end_char },
  }

  local seen = {} --- @type table<string, true>
  local items = {} --- @type lsp.CompletionItem[]
  local n = 0
  for _, file in ipairs(files or option_files(dict_opt)) do
    local data = read_file_async(file)
    if data then
      local batched = 0
      -- Iterate lines without materializing the whole split (gmatch over the
      -- read buffer). Each non-final line ends in "\n"; the last may not.
      for raw in (data .. '\n'):gmatch('(.-)\n') do
        -- Pull out every keyword on the line and test the prefix. Bytes
        -- >= 128 are included so multibyte dictionary words stay whole
        -- instead of splitting at every non-ASCII byte, matching the word
        -- class the includes/defines collectors already use. 'iskeyword'
        -- extras like '-' are still not honored: native matches with \k,
        -- and exact parity would need matchstrpos() per line -- too slow.
        for word in raw:gmatch('[%w_\128-\255]+') do
          if #word >= plen and word ~= prefix and not seen[word] then
            local keep = fuzzy or prefix == ''
            if not keep then
              local head = word:sub(1, plen)
              if icase then
                head = head:lower()
              end
              keep = head == cmp_prefix
            end
            if keep then
              seen[word] = true
              n = n + 1
              items[n] = {
                label = word,
                kind = CompletionItemKind.Text,
                sortText = ('%08d'):format(n),
                filterText = word,
                textEdit = { range = range, newText = word },
              }
              if n >= MAX_ITEMS then
                return items, true
              end
            end
          end
        end
        batched = batched + 1
        if batched >= SCAN_BATCH then
          batched = 0
          async.await(1, vim.schedule)
        end
      end
    end
  end
  return items, false
end

--- Collect thesaurus completions (CTRL-X CTRL-T): from the files in 'thesaurus'
--- (or the explicit `files` list, for a 'complete' "s{file}" entry),
--- find lines that contain a word starting with `prefix` and offer every word on
--- that line (synonyms). Mirrors ins_compl_files(thesaurus=true) +
--- thesaurus_add_words_in_line(). The leader is the keyword before the cursor.
--- @async
--- @param prefix string  keyword prefix typed so far
--- @param lnum integer  0-based cursor line (LSP)
--- @param start_char integer  utf-16 column where the prefix starts
--- @param end_char integer  utf-16 column at the cursor
--- @param files string[]?  explicit file list ('complete' "s{file}"); nil scans 'thesaurus'
--- @return lsp.CompletionItem[]
--- @return boolean truncated
local function collect_thesaurus(prefix, lnum, start_char, end_char, files)
  local opt = vim.bo.thesaurus
  if opt == nil or opt == '' then
    opt = vim.o.thesaurus
  end
  if not files and (opt == nil or opt == '') then
    return {}, false
  end

  local icase = vim.o.ignorecase
  if icase and vim.o.smartcase and prefix:match('%u') then
    icase = false
  end
  local cmp_prefix = icase and prefix:lower() or prefix
  local plen = #prefix

  local range = {
    start = { line = lnum, character = start_char },
    ['end'] = { line = lnum, character = end_char },
  }

  files = files or option_files(opt)

  --- Does the line contain a word whose start matches the prefix?
  --- @param words string[]
  --- @return boolean
  local function line_matches(words)
    if prefix == '' then
      return true
    end
    for _, w in ipairs(words) do
      local head = w:sub(1, plen)
      if icase then
        head = head:lower()
      end
      if #w >= plen and head == cmp_prefix then
        return true
      end
    end
    return false
  end

  local seen = {} --- @type table<string, true>
  local items = {} --- @type lsp.CompletionItem[]
  local n = 0
  for _, file in ipairs(files) do
    local data = read_file_async(file)
    if data then
      local batched = 0
      for raw in (data .. '\n'):gmatch('(.-)\n') do
        -- Collect the words on the line, then, if any starts with the prefix,
        -- offer them all (the matched word first via natural order). The word
        -- class includes bytes >= 128 so multibyte synonyms stay whole (see
        -- collect_dict).
        local words = {} --- @type string[]
        for word in raw:gmatch('[%w_\128-\255]+') do
          words[#words + 1] = word
        end
        if line_matches(words) then
          for _, word in ipairs(words) do
            if not seen[word] then
              seen[word] = true
              n = n + 1
              -- Synonyms don't start with the typed prefix, so set filterText to
              -- the prefix itself: the client keeps every word (they all "match"
              -- the leader) and inserts the synonym via newText. Mirrors native
              -- thesaurus, which shows all words on the matched line.
              items[n] = {
                label = word,
                kind = CompletionItemKind.Text,
                sortText = ('%08d'):format(n),
                filterText = prefix ~= '' and prefix or word,
                textEdit = { range = range, newText = word },
              }
              if n >= MAX_ITEMS then
                return items, true
              end
            end
          end
        end
        batched = batched + 1
        if batched >= SCAN_BATCH then
          batched = 0
          async.await(1, vim.schedule)
        end
      end
    end
  end
  return items, false
end

--- Collect tag completions (CTRL-X CTRL-]): tag names from the 'tags' files
--- that match `prefix`. Uses getcompletion(pat, 'tag'), which calls find_tags()
--- under the hood, so tag file parsing, 'tagcase'/'ignorecase' and the tag
--- search path are all handled natively. The leader is the keyword before the
--- cursor (CTRL_X_WANT_IDENT).
--- @async
--- @param prefix string  keyword prefix typed so far
--- @param lnum integer  0-based cursor line (LSP)
--- @param start_char integer  utf-16 column where the prefix starts
--- @param end_char integer  utf-16 column at the cursor
--- @return lsp.CompletionItem[]
--- @return boolean truncated
local function collect_tags(prefix, lnum, start_char, end_char)
  -- taglist() takes a regexp; anchor at the start for prefix matching. Reusing
  -- taglist (which calls find_tags underneath) gives us each tag's `cmd`, needed
  -- to honor 'showfulltag'. Pattern semantics mirror the native normal-pattern
  -- builder shared by CTRL-X CTRL-]: an empty base matches any tag of at
  -- least two keyword chars ("\<\k\k") and a single-byte base requires one
  -- more keyword char ("\<c\k") -- see get_normal_compl_info().
  local pat
  if prefix == '' then
    pat = '^\\k\\k'
  elseif #prefix == 1 then
    pat = '^' .. vim.fn.escape(prefix, '\\.*$^~[]/') .. '\\k'
  else
    pat = '^' .. vim.fn.escape(prefix, '\\.*$^~[]/')
  end
  local ok, tags = pcall(vim.fn.taglist, pat)
  if not ok or type(tags) ~= 'table' then
    return {}, false
  end

  local showfull = vim.o.showfulltag

  local range = {
    start = { line = lnum, character = start_char },
    ['end'] = { line = lnum, character = end_char },
  }

  --- With 'showfulltag', the inserted word is the tag's definition line (from
  --- its search-command address) rather than the bare tag name, mirroring
  --- native tag completion. Extract the text between the "/^" ... "$/" (or
  --- "?^" ... "?") anchors of the cmd.
  --- @param tag table
  --- @return string
  local function tag_word(tag)
    local name = tag.name or ''
    local cmd = tag.cmd or ''
    -- Line-number addresses (":42") have no definition text; keep the name.
    local body = cmd:match('^/%^?(.-)%$?/$') or cmd:match('^%?%^?(.-)%$?%?$')
    if body == nil or body == '' then
      return name
    end
    -- Unescape the few characters tag search commands escape.
    body = body:gsub('\\([/\\])', '%1')
    return body
  end

  local seen = {} --- @type table<string, true>
  local items = {} --- @type lsp.CompletionItem[]
  local n = 0
  for _, tag in ipairs(tags) do
    local name = tag.name or ''
    -- Under 'showfulltag' each tag contributes TWO candidates, mirroring the
    -- option's documented behavior ("show both the tag name and a tidied-up
    -- form of the search pattern as possible matches"): the bare name first,
    -- then the definition text extracted from the tag's search command.
    -- Without it a tag is just its name.
    local words = { name }
    if showfull then
      local defn = tag_word(tag)
      if defn ~= '' and defn ~= name then
        words[#words + 1] = defn
      end
    end
    for _, word in ipairs(words) do
      if word ~= '' and not seen[word] then
        seen[word] = true
        n = n + 1
        -- The definition candidate does not start with the typed prefix. Keep
        -- `label` as the tag name so the client's prefix filter still
        -- matches, and put the definition only in textEdit.newText.
        -- Crucially do NOT set filterText: fallback_filtertext() in the
        -- client would otherwise see newText not matching the prefix and
        -- replace the inserted word with filterText, dropping the definition.
        items[n] = {
          label = name,
          kind = CompletionItemKind.Text,
          sortText = ('%08d'):format(n),
          textEdit = { range = range, newText = word },
        }
        if n >= MAX_ITEMS then
          return items, true
        end
      end
    end
  end
  return items, false
end

--- Collect command-line completions (CTRL-X CTRL-V): treat the text before
--- the cursor as an Ex command and offer what the command line would.
--- Reuses getcompletion(..., 'cmdline'), which drives the same
--- set_cmd_context()/ExpandFromContext() pair as the native
--- get_next_cmdline_completion(). The replaced range starts at `startcol`,
--- the xp_pattern offset the C routing gate computed with set_cmd_context()
--- (compl_col in get_cmdline_compl_info()).
---
--- Native shows every match ExpandFromContext() produced, without another
--- prefix pass -- with a glob typed ("*.c") or 'wildoptions' "fuzzy" the
--- candidates need not start with the base at all. filterText echoes the
--- base so the client's filter keeps them, and data.keep_word stops
--- fallback_filtertext() from swapping the inserted text for that filter
--- value.
--- @param line string  cursor line
--- @param col integer  0-based byte cursor column
--- @param startcol integer  0-based byte column where xp_pattern starts
--- @param position lsp.Position
--- @return lsp.CompletionItem[]
--- @return boolean truncated
local function collect_cmdline(line, col, startcol, position)
  if startcol > col then
    startcol = col
  end
  local ok, matches = pcall(vim.fn.getcompletion, line:sub(1, col), 'cmdline')
  if not ok or type(matches) ~= 'table' then
    return {}, false
  end

  local start_char = vim.str_utfindex(line, 'utf-16', math.min(startcol, #line), false)
  local range = {
    start = { line = position.line, character = start_char },
    ['end'] = { line = position.line, character = position.character },
  }
  local base = line:sub(startcol + 1, col)

  local seen = {} --- @type table<string, true>
  local items = {} --- @type lsp.CompletionItem[]
  local n = 0
  for _, m in ipairs(matches) do
    if m ~= '' and not seen[m] then
      seen[m] = true
      n = n + 1
      items[n] = {
        label = m,
        kind = CompletionItemKind.Text,
        sortText = ('%08d'):format(n),
        filterText = base ~= '' and base or nil,
        data = base ~= '' and { keep_word = true } or nil,
        textEdit = { range = range, newText = m },
      }
      if n >= MAX_ITEMS then
        return items, true
      end
    end
  end
  return items, false
end

--- Collect register-word completions (CTRL-X CTRL-R): every 'iskeyword' word
--- in the writable registers that starts with the keyword base. Mirrors
--- get_register_completion(): the register set is the yank-register array
--- ('"', 0-9, a-z, '-', '*', '+'; the black hole '_' is skipped), words are
--- \k+ runs (find_word_start()/find_word_end()), and the prefix filter uses
--- 'ignorecase' alone -- no 'smartcase', native compares with
--- STRNICMP/strncmp on p_ic directly. The trigger key CTRL-R is always a
--- FORWARD search (ins_compl_key2dir()), so there is no backward variant;
--- the ADDING continuation of a repeated ^X^R stays native.
---
--- Items are plain labels: like the keyword collector's buffer words, every
--- match starts with the keyword base, so the client's default word
--- boundary places the insertion -- no per-item textEdit needed (native
--- compl_col is the same keyword start, via get_normal_compl_info()).
--- @param prefix string  keyword prefix typed so far
--- @return lsp.CompletionItem[]
--- @return boolean truncated
local function collect_registers(prefix)
  local icase = vim.o.ignorecase
  local cmp_prefix = icase and prefix:lower() or prefix
  local plen = #prefix

  -- get_register_name() order: unnamed, numbered, small delete, named,
  -- selection registers. '_' would be skipped by the native loop; it is
  -- simply not listed here.
  local regs = { '"', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '-' }
  for c = ('a'):byte(), ('z'):byte() do
    regs[#regs + 1] = string.char(c)
  end
  regs[#regs + 1] = '*'
  regs[#regs + 1] = '+'

  local seen = {} --- @type table<string, true>
  local items = {} --- @type lsp.CompletionItem[]
  local n = 0
  for _, r in ipairs(regs) do
    -- getreg(..., 1, true): list of lines, no NUL mangling, no expression
    -- re-evaluation ('=' is not in the set above).
    local ok, val = pcall(vim.fn.getreg, r, 1, true)
    if ok and type(val) == 'table' then
      for _, str in ipairs(val) do
        local from = 0
        while true do
          --- @type string, integer, integer
          local word, s, e = unpack(vim.fn.matchstrpos(str, [[\k\+]], from))
          if s == -1 then
            break
          end
          from = e
          local keep = word ~= '' and not seen[word]
          if keep and plen > 0 then
            local head = word:sub(1, plen)
            if icase then
              head = head:lower()
            end
            keep = head == cmp_prefix
          end
          if keep then
            seen[word] = true
            n = n + 1
            items[n] = {
              label = word,
              kind = CompletionItemKind.Text,
              sortText = ('%08d'):format(n),
            }
            if n >= MAX_ITEMS then
              return items, true
            end
          end
        end
      end
    end
  end
  return items, false
end

--- Buffer-name completion ('complete' flag "f"): the tail of every listed
--- buffer's name that starts with the base. Mirrors get_next_bufname_token():
--- b_p_bl && b_sfname != NULL, path_tail(), and a case-SENSITIVE strncmp()
--- against the typed base regardless of 'ignorecase' (only the later
--- duplicate/leader comparison is CP_ICASE-aware).
--- @param prefix string  keyword prefix typed so far
--- @param lnum integer  0-based cursor line (LSP)
--- @param start_char integer  utf-16 column where the prefix starts
--- @param end_char integer  utf-16 column at the cursor
--- @return lsp.CompletionItem[]
--- @return boolean truncated
local function collect_bufnames(prefix, lnum, start_char, end_char)
  local range = {
    start = { line = lnum, character = start_char },
    ['end'] = { line = lnum, character = end_char },
  }
  local seen = {} --- @type table<string, true>
  local items = {} --- @type lsp.CompletionItem[]
  local n = 0
  for _, b in ipairs(api.nvim_list_bufs()) do
    if vim.bo[b].buflisted then
      local name = api.nvim_buf_get_name(b)
      if name ~= '' then
        local tail = vim.fn.fnamemodify(name, ':t')
        if tail ~= '' and vim.startswith(tail, prefix) and not seen[tail] then
          seen[tail] = true
          n = n + 1
          items[n] = {
            label = tail,
            kind = CompletionItemKind.File,
            sortText = ('%08d'):format(n),
            textEdit = { range = range, newText = tail },
          }
          if n >= MAX_ITEMS then
            return items, true
          end
        end
      end
    end
  end
  return items, false
end

--- @param params lsp.CompletionParams
--- @return integer? bufnr
--- @return string line
--- @return integer col  0-based byte column
local function resolve_position(params)
  -- Resolve the target buffer from the document URI. For unnamed/scratch
  -- buffers the URI round-trip is lossy ("file://" with no path), so fall back
  -- to the current buffer -- safe here because, as an in-process server, the
  -- request is driven synchronously from that buffer.
  local uri = params.textDocument and params.textDocument.uri
  local bufnr = uri and vim.uri_to_bufnr(uri) or nil
  if not bufnr or not api.nvim_buf_is_loaded(bufnr) then
    bufnr = api.nvim_get_current_buf()
  end
  if not api.nvim_buf_is_loaded(bufnr) then
    return nil, '', 0
  end
  local pos = params.position
  local line = api.nvim_buf_get_lines(bufnr, pos.line, pos.line + 1, false)[1] or ''
  -- position.character is utf-16 here; convert to a byte column.
  local ok, byte_col = pcall(vim.str_byteindex, line, 'utf-16', pos.character, false)
  return bufnr, line, ok and byte_col or math.min(pos.character, #line)
end

--- @async
--- @param params lsp.CompletionParams
--- @return lsp.CompletionList
--- Byte/utf-16 boundary helpers shared by the collectors. Given the line and
--- the 0-based byte cursor column, returns the LSP line number, the utf-16
--- start column for `prefix`, and the utf-16 end column at the cursor.
--- @param line string
--- @param col integer  0-based byte column of the cursor
--- @param prefix string  leader whose start anchors the textEdit
--- @param position lsp.Position
--- @return integer lnum
--- @return integer start_char
--- @return integer end_char
local function edit_bounds(line, col, prefix, position)
  local start_byte = col - #prefix
  local start_char = vim.str_utfindex(line, 'utf-16', start_byte, false)
  return position.line, start_char, position.character
end

--- Each collector has the signature function(a) -> items, truncated, where `a`
--- bundles the resolved request. Keyword completion is the default (mode nil or
--- "keyword"); the CTRL-X submodes key off their mode string. New sources can be
--- added by dropping another entry in this table.
--- @class vim.lsp.completion._server.CollectArgs
--- @field bufnr integer
--- @field line string
--- @field col integer            0-based byte cursor column
--- @field local_only boolean?
--- @field backward boolean?
--- @field position lsp.Position
--- @field startcol integer?      0-based byte base start from the C gate (cmdline)

--- @type table<string, fun(a: vim.lsp.completion._server.CollectArgs): lsp.CompletionItem[], boolean>
--- Expand one level of includes: lines of `bufnr` plus the lines of every
--- file matched by the 'include' pattern in them (filename taken from the
--- first quoted/bracketed group after the match; looked up relative to the
--- buffer's directory and the current directory). Deeper recursion and
--- 'path'/'includeexpr' handling are TODO -- this mirrors what the current
--- tests exercise.
--- @async
--- @param bufnr integer
--- @return string[]
local function include_lines(bufnr)
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local out = {} --- @type string[]
  vim.list_extend(out, lines)
  -- 'include' is global-local: an empty buffer-local value falls back to
  -- the global (the tests use plain :set), then to the C default.
  local inc_pat = vim.bo[bufnr].include
  if inc_pat == '' then
    inc_pat = vim.o.include
  end
  if inc_pat == '' then
    inc_pat = [[^\s*#\s*include]]
  end
  local bufdir = vim.fs.dirname(api.nvim_buf_get_name(bufnr))
  for _, line in ipairs(lines) do
    local ok, m = pcall(vim.fn.match, line, inc_pat)
    if ok and m >= 0 then
      local fname = line:match('["<]([^">]+)[">]', m + 1)
      if fname and fname ~= '' then
        for _, dir in ipairs({ bufdir, vim.uv.cwd() }) do
          local path = dir and (dir .. '/' .. fname) or fname
          -- Unified async file reading (read_file_uv under a coroutine hop):
          -- asynchronous collection is the feature. The hop defers this
          -- batch past the current keystroke; packed-typeahead tests that
          -- press the next key immediately are adapted on the test side.
          local data = read_file_async(path)
          if data then
            for l in vim.gsplit(data, '\n', { plain = true }) do
              out[#out + 1] = l
            end
            break
          end
        end
      end
    end
  end
  return out
end

--- Included-file keyword completion (CTRL-X CTRL-I, cpt "i"): \k words
--- matching the prefix from the current buffer and included files.
---
--- The base's own occurrence -- the word being typed, starting at byte column
--- `base_scol` on the cursor line -- is skipped *positionally*, mirroring the
--- "skip the match at the cursor" check in find_pattern_in_path()
--- (ACTION_EXPAND). Without it the typed base always reappears as a candidate
--- of itself, which e.g. caps the 'completeopt' "longest" prefix at the base
--- (Test_smartcase_longest). Exclusion is positional, not textual: another
--- occurrence of the same word (here or in an included file) stays a
--- legitimate match, same as the buffer scan's part='left'/'right' logic.
--- @async
--- @param base_scol integer  0-based byte column where the base starts
local function collect_includes(prefix, lnum, start_char, end_char, bufnr, base_scol)
  local range = {
    start = { line = lnum, character = start_char },
    ['end'] = { line = lnum, character = end_char },
  }
  local seen = {} --- @type table<string, true>
  local items = {} --- @type lsp.CompletionItem[]
  local n = 0
  local min_len = #prefix <= 1 and 2 or #prefix
  -- include_lines() returns the buffer's own lines first, in order, so the
  -- cursor line sits at index lnum+1; included-file lines only follow after.
  local base_idx = lnum + 1
  for i, line in ipairs(include_lines(bufnr)) do
    for s, word in line:gmatch('()([%w_\128-\255]+)') do
      local at_base = i == base_idx and s - 1 == base_scol
      if not at_base and #word >= min_len and word:sub(1, #prefix) == prefix and not seen[word] then
        seen[word] = true
        n = n + 1
        items[n] = {
          label = word,
          kind = CompletionItemKind.Text,
          sortText = ('%08d'):format(n),
          textEdit = { range = range, newText = word },
        }
        if n >= MAX_ITEMS then
          return items, true
        end
      end
    end
  end
  return items, false
end

--- Defined-identifier completion (CTRL-X CTRL-D, cpt "d"): for every line of
--- the current buffer and included files that matches the 'define' pattern,
--- the identifier is the first \k+ run after the match. A definition whose
--- line continues past the identifier is marked cont_s_ipos, feeding the
--- native CONT_S_IPOS -> CONT_SOL add-expansion walk of repeated ^X^D.
--- @async
--- @param base_scol integer  0-based byte column where the base starts
local function collect_defines(prefix, lnum, start_char, end_char, bufnr, base_scol)
  local range = {
    start = { line = lnum, character = start_char },
    ['end'] = { line = lnum, character = end_char },
  }
  -- 'define' is global-local, same fallback chain as 'include' above.
  local def_pat = vim.bo[bufnr].define
  if def_pat == '' then
    def_pat = vim.o.define
  end
  if def_pat == '' then
    def_pat = [[^\s*#\s*define]]
  end
  local seen = {} --- @type table<string, true>
  local items = {} --- @type lsp.CompletionItem[]
  local n = 0
  -- Cursor line index in include_lines() output; see collect_includes.
  local base_idx = lnum + 1
  for i, line in ipairs(include_lines(bufnr)) do
    local ok, mend = pcall(vim.fn.matchend, line, def_pat)
    if ok and mend >= 0 then
      local rest = line:sub(mend + 1)
      local pre_ws, word, tail = rest:match('^([^%w_\128-\255]*)([%w_\128-\255]+)(.*)$')
      -- Same positional base skip as collect_includes: the identifier being
      -- typed (e.g. completing right after "#define FO") must not offer
      -- itself. mend is the 0-based byte end of the 'define' match, so the
      -- identifier starts at byte mend + #pre_ws.
      local at_base = word ~= nil and i == base_idx and (mend + #pre_ws) == base_scol
      if not at_base and word and word:sub(1, #prefix) == prefix and not seen[word] then
        seen[word] = true
        n = n + 1
        items[n] = {
          label = word,
          kind = CompletionItemKind.Text,
          sortText = ('%08d'):format(n),
          textEdit = { range = range, newText = word },
          data = (tail ~= nil and tail:match('%S') ~= nil) and { cont_s_ipos = true } or nil,
        }
        if n >= MAX_ITEMS then
          return items, true
        end
      end
    end
  end
  return items, false
end

local collectors = {
  files = function(a)
    local prefix = filename_prefix(a.line, a.col)
    local lnum, start_char, end_char = edit_bounds(a.line, a.col, prefix, a.position)
    return collect_files(prefix, lnum, start_char, end_char)
  end,

  lines = function(a)
    local leader, indent = line_prefix(a.line, a.col)
    return collect_lines(
      leader,
      indent,
      a.bufnr,
      a.local_only,
      a.position.line,
      a.position.character,
      a.backward
    )
  end,

  dictionary = function(a)
    local prefix = keyword_prefix(a.line, a.col)
    local lnum, start_char, end_char = edit_bounds(a.line, a.col, prefix, a.position)
    return collect_dict(prefix, lnum, start_char, end_char)
  end,

  thesaurus = function(a)
    local prefix = keyword_prefix(a.line, a.col)
    local lnum, start_char, end_char = edit_bounds(a.line, a.col, prefix, a.position)
    return collect_thesaurus(prefix, lnum, start_char, end_char)
  end,

  tags = function(a)
    local prefix = keyword_prefix(a.line, a.col)
    local lnum, start_char, end_char = edit_bounds(a.line, a.col, prefix, a.position)
    return collect_tags(prefix, lnum, start_char, end_char)
  end,

  includes = function(a)
    local prefix = keyword_prefix(a.line, a.col)
    local lnum, start_char, end_char = edit_bounds(a.line, a.col, prefix, a.position)
    return collect_includes(prefix, lnum, start_char, end_char, a.bufnr, a.col - #prefix)
  end,

  defines = function(a)
    local prefix = keyword_prefix(a.line, a.col)
    local lnum, start_char, end_char = edit_bounds(a.line, a.col, prefix, a.position)
    return collect_defines(prefix, lnum, start_char, end_char, a.bufnr, a.col - #prefix)
  end,

  cmdline = function(a)
    -- The pattern start comes from the C gate (set_cmd_context()); without it
    -- there is no way to place the replaced range, so fall back to "insert at
    -- the cursor" like the native EXPAND_UNSUCCESSFUL case.
    return collect_cmdline(a.line, a.col, a.startcol or a.col, a.position)
  end,

  register = function(a)
    return collect_registers(keyword_prefix(a.line, a.col))
  end,
}

--- Keyword completion (CTRL-N / CTRL-X CTRL-N): scan the target buffers for
--- words matching the keyword prefix, in native search order. This is the
--- default when no mode is set.
---
--- Order and selection contract (ins_compl_add() + set_completion()): items
--- are collected in the order the native search finds them -- the current
--- buffer from the cursor in the search direction with wraparound, other
--- buffers whole, words within a line following the direction. A BACKWARD
--- find is linked *before* the current match, so the native list reads
--- back-to-front of the find order and the initial CTRL-P selection lands on
--- the list tail = the first find = the nearest match above the cursor.
--- Reversed sortText reproduces exactly that through the client sort.
---
--- Matches whose text equals the typed base are kept: ins_compl_add()'s
--- duplicate scan skips the CP_ORIGINAL_TEXT entry, so a real occurrence of
--- the base elsewhere is a legitimate match (Test_completion_restart expects
--- exactly one such item; Test_ins_complete's first chain steps over one).
--- Only the occurrence being typed -- starting at the completion column on
--- the cursor line -- is never offered.
---
--- An empty base uses the native "\<\k\k" pattern: any word of at least two
--- characters (compl_from_nonkeyword). That includes "adding from the
--- original empty text": get_normal_compl_info() drops the ADDING flags when
--- compl_length < 1 and the session restarts as a plain completion.
--- @async
--- @param a vim.lsp.completion._server.CollectArgs
--- @return lsp.CompletionItem[]
--- @return boolean truncated
local function collect_keyword(a)
  local prefix = keyword_prefix(a.line, a.col)
  local plen = #prefix
  -- Case handling mirrors insexpand.c: with 'ignorecase' (and, when
  -- 'smartcase' is set, only if the typed prefix has no uppercase) the prefix
  -- match is case-insensitive.
  local icase = vim.o.ignorecase
  if icase and vim.o.smartcase and prefix:match('%u') then
    icase = false
  end
  local cmp_prefix = icase and prefix:lower() or prefix
  -- Native pattern semantics: an empty base scans "\\<\\k\\k" and a
  -- single-byte base scans "\\<c\\k" (insexpand.c only quote_meta()s the
  -- base when compl_length > 1), so both require words of at least two
  -- characters -- a bare word equal to a 1-char base is never a candidate.
  local min_len = plen <= 1 and 2 or plen
  -- 'completeopt' "nearest" (native is_nearest_active(): the "fuzzy" flag
  -- wins and disables it; the compl_autocomplete arm of the predicate never
  -- routes here). Distances are |lnum - cursor line|, current buffer only --
  -- cp_compare_nearest() treats matches without one as neutral.
  local nearest = cot_has(a.bufnr, 'nearest') and not cot_has(a.bufnr, 'fuzzy')
  -- Per-word nearest ordering key, keyed by index into `words`. Encoding
  -- derived from Test_nearest_cpt_option (all 16 layout/direction cases):
  --   * on/below the cursor line: 2*|dlnum|; above it: 2*|dlnum| + 1, i.e. at
  --     equal distance the occurrence BELOW the cursor sorts first, and the
  --     order is independent of the trigger direction (the ^N and ^P variants
  --     expect identical lists);
  --   * a duplicate word keeps the MINIMUM key over its occurrences -- the
  --     test's "Reposition match" cases; native does the same at add time
  --     (ins_compl_add() lowers cp_score on a smaller-score duplicate).
  -- Words without a key (other buffers, extra cpt sources) sort after all
  -- keyed words in found order. Native's own nearest re-sort
  -- (sort_compl_match_list(cp_compare_nearest)) is a stable merge sort and
  -- ins_compl_add_tv() gives every item FUZZY_SCORE_NONE, which
  -- cp_compare_nearest() treats as "no opinion" -- so the order computed here
  -- survives the native session unchanged and is authoritative.
  local nearest_keys = {} --- @type table<integer, integer>
  -- cot=fuzzy with a non-empty base switches candidate GATHERING to fuzzy
  -- matching (native in_fuzzy_collect: fuzzy_match_str_in_line() extracts any
  -- word the base fuzzy-matches; the prefix and the 2-char minimum are
  -- irrelevant). The empty-base path is unchanged -- native requires
  -- compl_length > 0. Ordering is the client's job here: under cot=fuzzy it
  -- sorts by matchfuzzypos() score, the same engine C's set_fuzzy_score()
  -- reuses on every leader change.
  local fuzzy_collect = plen > 0 and cot_has(a.bufnr, 'fuzzy')
  local fuzzy_cache = {} --- @type table<string, boolean>
  local base_lnum = a.position.line + 1 -- 1-based cursor line
  local base_scol = a.col - plen -- 0-based byte column of the base start
  log.warn(
    string.format(
      'BUILTIN base DIAG: prefix=%q base_lnum=%d base_scol=%d a.col=%d line1=%q line2=%q cot=%q',
      prefix,
      base_lnum,
      base_scol,
      a.col,
      api.nvim_buf_get_lines(a.bufnr, 0, 1, false)[1] or '',
      api.nvim_buf_get_lines(a.bufnr, 1, 2, false)[1] or '',
      effective_cot(a.bufnr)
    )
  )

  local words = {} --- @type string[]
  local seen = {} --- @type table<string, integer>  -- word -> index in `words`
  local truncated = false

  -- Record one find; duplicates keep the first find, as the native duplicate
  -- scan runs at add time. Returns 'cap' when the global item cap is hit,
  -- 'added' when the word was recorded, false for a duplicate; the second
  -- value is the word's index in `words` (new or existing), so callers can
  -- update per-word state (the nearest key) for duplicate occurrences too.
  local function take(word)
    local existing = seen[word]
    if existing then
      return false, existing
    end
    local idx = #words + 1
    seen[word] = idx
    words[idx] = word
    if idx >= MAX_ITEMS then
      truncated = true
      return 'cap', idx
    end
    return 'added', idx
  end

  local function match_word(word)
    if fuzzy_collect then
      local hit = fuzzy_cache[word]
      if hit == nil then
        hit = #vim.fn.matchfuzzy({ word }, prefix) > 0
        fuzzy_cache[word] = hit
      end
      return hit
    end
    if #word < min_len then
      return false
    end
    if plen > 0 then
      local head = word:sub(1, plen)
      if icase then
        head = head:lower()
      end
      if head ~= cmp_prefix then
        return false
      end
    end
    return true
  end

  -- Walk one raw line's matching \k\+ occurrences in search order and record
  -- them. part restricts the cursor line to the words after the cursor
  -- ('right') or before the base ('left'); the base occurrence itself falls
  -- in neither and is never offered. budget is the cpt entry's "^count" match
  -- allowance ({ left = n }) or nil for unlimited; only *added* matches
  -- consume it -- non-matching words and duplicates don't
  -- (Test_complete_match_count's free/freebar case). Returns 'cap' when the
  -- global item cap is hit, 'entry' when the entry budget ran out, nil to
  -- continue.
  --- @param raw string
  --- @param part string?
  --- @param budget { left: integer }?
  --- @param line_key integer?  nearest key of this line (cursor-buffer only)
  --- @return 'cap'|'entry'|nil
  local function visit(raw, part, budget, line_key)
    local occ = {} --- @type {word: string, scol: integer}[]
    local from = 0
    while true do
      --- @type string, integer, integer
      local word, s, e = unpack(vim.fn.matchstrpos(raw, [[\k\+]], from))
      if s == -1 then
        break
      end
      from = e
      if match_word(word) then
        occ[#occ + 1] = { word = word, scol = s }
      end
    end
    local lo, hi, step = 1, #occ, 1
    if a.backward then
      lo, hi, step = #occ, 1, -1
    end
    for i = lo, hi, step do
      local o = occ[i]
      local ok = part == nil
        or (part == 'right' and o.scol >= a.col)
        or (part == 'left' and o.scol < base_scol)
      if ok then
        if budget and budget.left <= 0 then
          return 'entry'
        end
        local r, idx = take(o.word)
        if line_key then
          local k = nearest_keys[idx]
          if not k or line_key < k then
            nearest_keys[idx] = line_key
          end
        end
        if r == 'cap' then
          return 'cap'
        end
        if r == 'added' and budget then
          budget.left = budget.left - 1
          if budget.left <= 0 then
            return 'entry'
          end
        end
      end
    end
    return nil
  end

  -- Scan one buffer in native search order under an optional entry budget.
  -- Returns 'cap'/'entry'/nil like visit().
  --- @param buf integer
  --- @param budget { left: integer }?
  --- @return 'cap'|'entry'|nil
  local function scan_buf(buf, budget)
    if api.nvim_buf_is_loaded(buf) then
      local cnt = api.nvim_buf_line_count(buf)
      --- Visit plan: 1-based lnum plus the cursor-line part restriction. The
      --- current buffer starts at the cursor and wraps ('wrapscan' is forced
      --- there); other buffers are scanned whole in the search direction.
      --- @type {l: integer, part: string?}[]
      local plan = {}
      if buf == a.bufnr then
        if a.backward then
          plan[#plan + 1] = { l = base_lnum, part = 'left' }
          for l = base_lnum - 1, 1, -1 do
            plan[#plan + 1] = { l = l }
          end
          for l = cnt, base_lnum + 1, -1 do
            plan[#plan + 1] = { l = l }
          end
          plan[#plan + 1] = { l = base_lnum, part = 'right' }
        else
          plan[#plan + 1] = { l = base_lnum, part = 'right' }
          for l = base_lnum + 1, cnt do
            plan[#plan + 1] = { l = l }
          end
          for l = 1, base_lnum - 1 do
            plan[#plan + 1] = { l = l }
          end
          plan[#plan + 1] = { l = base_lnum, part = 'left' }
        end
      elseif a.backward then
        for l = cnt, 1, -1 do
          plan[#plan + 1] = { l = l }
        end
      else
        for l = 1, cnt do
          plan[#plan + 1] = { l = l }
        end
      end
      for i, st in ipairs(plan) do
        local raw = api.nvim_buf_get_lines(buf, st.l - 1, st.l, false)[1] or ''
        local line_key --- @type integer?
        if nearest and buf == a.bufnr then
          local d = st.l - base_lnum
          line_key = d >= 0 and 2 * d or -2 * d + 1
        end
        local stop = visit(raw, st.part, budget, line_key)
        if stop then
          return stop
        end
        if i % SCAN_BATCH == 0 then
          async.await(1, vim.schedule)
        end
      end
    else
      -- An unloaded buffer (cpt 'u'/'U') has no in-memory lines; native scans
      -- it from its file, skipping buffers without a real filename. Skip
      -- anything that isn't a readable regular file (an empty buffer name
      -- resolves to a directory) to avoid an EISDIR read.
      local fname = api.nvim_buf_get_name(buf)
      local stat = fname ~= '' and uv.fs_stat(fname) or nil
      if stat and stat.type == 'file' then
        local data = read_file_async(fname)
        if data then
          local raws = {} --- @type string[]
          for raw in (data .. '\n'):gmatch('(.-)\n') do
            raws[#raws + 1] = raw
          end
          local lo, hi, step = 1, #raws, 1
          if a.backward then
            lo, hi, step = #raws, 1, -1
          end
          local scanned = 0
          for i = lo, hi, step do
            local stop = visit(raws[i], nil, budget, nil)
            if stop then
              return stop
            end
            scanned = scanned + 1
            if scanned % SCAN_BATCH == 0 then
              async.await(1, vim.schedule)
            end
          end
        end
      end
    end
    return nil
  end

  -- Buffer scan, grouped by 'complete' entry so each entry's "^count" match
  -- budget applies to exactly the buffers that entry selects (".^2,w" caps
  -- current-buffer matches at 2 while 'w' stays unlimited). Semantics pinned
  -- by Test_complete_match_count:
  --   * "^0" (and no count) means unlimited;
  --   * the budget is ignored on a BACKWARD trigger ("max_matches is ignored
  --     for backward search");
  --   * only added matches consume it (non-matching words and duplicates
  --     don't).
  -- A buffer already scanned by an earlier entry is skipped, mirroring the
  -- native b_scanned flag: with "w^1,b" a window's buffer contributes at most
  -- its 'w' quota; the 'b' entry must not rescan it uncapped.
  --
  -- TODO(builtin-completion): under cot=fuzzy the native limit applies to the
  -- fuzzy-RANKED list and is re-applied on every leader change (per-source
  -- attribution via cp_cpt_source_idx in insexpand.c): ".^1" on
  -- abcd/abac/abdc must end up keeping "abac" once the leader reaches "ac",
  -- which a collection-time cut in found order cannot know. Until per-source
  -- attribution is bridged into the session, fuzzy collection stays uncapped.
  local scanned_bufs = {} --- @type table<integer, true>
  --- @type { bufs: integer[], max: integer? }[]
  local groups = {}
  if a.local_only then
    -- |i_CTRL-X_CTRL-N| ignores 'complete', and therefore any counts.
    groups[1] = { bufs = { a.bufnr } }
  else
    for _, e in ipairs(parse_cpt(api.nvim_get_option_value('complete', { buf = a.bufnr }))) do
      local bufs = buffers_for_flag(e.kind, a.bufnr)
      if bufs then
        groups[#groups + 1] = { bufs = bufs, max = e.max }
      end
    end
  end
  for _, group in ipairs(groups) do
    local budget --- @type { left: integer }?
    if not a.backward and not fuzzy_collect and group.max and group.max > 0 then
      budget = { left = group.max }
    end
    local stop --- @type 'cap'|'entry'|nil
    for _, buf in ipairs(group.bufs) do
      if not scanned_bufs[buf] then
        scanned_bufs[buf] = true
        stop = scan_buf(buf, budget)
        if stop then
          break
        end
      end
    end
    if stop == 'cap' then
      break
    end
  end

  log.warn(
    string.format(
      'BUILTIN collect_keyword: prefix=%q ic=%s scs=%s backward=%s words=%s',
      prefix,
      tostring(vim.o.ignorecase),
      tostring(vim.o.smartcase),
      tostring(a.backward),
      vim.inspect(words, { newline = '', indent = '' })
    )
  )
  -- 'complete' aggregation for plain CTRL-N (|i_CTRL-N|): non-buffer sources
  -- contribute FULL items after the buffer scan, in cpt order: textEdit,
  -- filterText and data must survive to the client (thesaurus synonyms pass
  -- the client filter only via their filterText, 'showfulltag' definition
  -- lines insert textEdit.newText, defines carry cont_s_ipos in data), so
  -- they are never flattened to labels here. Native interleaves
  -- strictly by cpt position; buffer-words-first is a deliberate v1
  -- simplification (no current test mixes buffer flags *after* other
  -- sources). Per-source "^count" limits apply to forward completion only
  -- (:h 'complete'). The kspell and F/o function sources are TODO (see the
  -- migration plan); i/d land with the includes/defines collectors, f
  -- (buffer names) has its branch below.
  local extra_items = {} --- @type lsp.CompletionItem[]
  if not a.local_only then
    local elnum, eschar, eechar = edit_bounds(a.line, a.col, prefix, a.position)
    local seen_words = {} --- @type table<string, true>
    for _, w in ipairs(words) do
      seen_words[w] = true
    end
    for _, e in ipairs(parse_cpt(api.nvim_get_option_value('complete', { buf = a.bufnr }))) do
      local extra --- @type lsp.CompletionItem[]?
      local extra_trunc = false
      if e.kind == 't' or e.kind == ']' then
        extra, extra_trunc = collect_tags(prefix, elnum, eschar, eechar)
      elseif e.kind == 'f' then
        extra, extra_trunc = collect_bufnames(prefix, elnum, eschar, eechar)
      elseif e.kind == 'k' then
        local files --- @type string[]?
        if e.arg then
          local ok, globbed = pcall(vim.fn.glob, e.arg, false, true)
          files = (ok and type(globbed) == 'table' and #globbed > 0) and globbed or nil
        end
        if not e.arg or files then
          extra, extra_trunc = collect_dict(prefix, elnum, eschar, eechar, files)
        end
      elseif e.kind == 's' then
        -- "s{file}" scans an explicit thesaurus file; patterns are valid
        -- (:h 'complete'). Mirrors the "k{file}" branch above.
        local files --- @type string[]?
        if e.arg then
          local ok, globbed = pcall(vim.fn.glob, e.arg, false, true)
          files = (ok and type(globbed) == 'table' and #globbed > 0) and globbed or nil
        end
        if not e.arg or files then
          extra, extra_trunc = collect_thesaurus(prefix, elnum, eschar, eechar, files)
        end
      elseif e.kind == 'i' then
        extra, extra_trunc = collect_includes(prefix, elnum, eschar, eechar, a.bufnr, base_scol)
      elseif e.kind == 'd' then
        extra, extra_trunc = collect_defines(prefix, elnum, eschar, eechar, a.bufnr, base_scol)
      end
      -- A truncated extra source must surface as isIncomplete too, so the
      -- client re-queries it as the prefix narrows.
      truncated = truncated or extra_trunc
      if extra then
        local added = 0
        for _, it in ipairs(extra) do
          -- Dedupe on the text a match INSERTS, not on the label:
          -- 'showfulltag' definition items share their label with the plain
          -- tag name but insert different text.
          local w = (it.textEdit and it.textEdit.newText) or it.label
          if w ~= '' and not seen_words[w] then
            seen_words[w] = true
            extra_items[#extra_items + 1] = it
            added = added + 1
            if e.max and not a.backward and added >= e.max then
              break
            end
          end
        end
      end
    end
  end

  log.warn(
    string.format(
      'BUILTIN collect_keyword FINAL: prefix=%q n=%d extras=%d words=%s',
      prefix,
      #words,
      #extra_items,
      vim.inspect(words, { newline = '', indent = '' })
    )
  )
  local total = #words
  local items = {} --- @type lsp.CompletionItem[]
  -- Extras rank after every buffer word on forward/nearest; on backward they
  -- rank BEFORE the (shifted) buffer words: the reversal must keep the sorted
  -- list's tail at the first-found buffer word -- the nearest match above the
  -- cursor, where the initial CTRL-P selection lands. (Previously the extras
  -- lived inside `words`, so the reversal covered them and produced the same
  -- tail.)
  local extras_first = not nearest and a.backward
  local kw_offset = extras_first and #extra_items or 0
  if nearest then
    -- Ascending by the nearest key (see nearest_keys above): distance first,
    -- below-the-cursor before above at equal distance, direction-independent.
    -- Equal keys can only come from the same line (or from unkeyed words:
    -- other buffers, which sort last among the buffer words); found index
    -- keeps those in scan order. Cpt extras are appended after everything.
    local order = {} --- @type integer[]
    for idx = 1, total do
      order[idx] = idx
    end
    table.sort(order, function(x, y)
      local kx = nearest_keys[x] or math.huge
      local ky = nearest_keys[y] or math.huge
      if kx ~= ky then
        return kx < ky
      end
      return x < y
    end)
    for rank, idx in ipairs(order) do
      items[idx] = {
        label = words[idx],
        kind = CompletionItemKind.Text,
        sortText = ('%08d'):format(rank),
      }
    end
  else
    for idx = 1, total do
      items[idx] = {
        label = words[idx],
        kind = CompletionItemKind.Text,
        sortText = ('%08d'):format(kw_offset + (a.backward and (total - idx + 1) or idx)),
      }
    end
  end
  for i, it in ipairs(extra_items) do
    -- In-place: collectors build fresh items per request, so overwriting the
    -- collector-local sortText with the merged rank is safe.
    it.sortText = ('%08d'):format(extras_first and i or (total + i))
    items[#items + 1] = it
  end
  return items, truncated
end

local function do_complete(params)
  local bufnr, line, col = resolve_position(params)
  if not bufnr then
    return { isIncomplete = false, items = {} }
  end

  local ctx = params.context --[[@as vim.lsp.completion._server.Context?]]
  local args = {
    bufnr = bufnr,
    line = line,
    col = col,
    local_only = ctx and ctx.local_only,
    backward = ctx and ctx.backward,
    position = params.position,
    startcol = ctx and ctx.startcol,
  }

  -- Dispatch on the source mode; keyword is the default (mode nil/"keyword").
  -- ADDING rounds (|complete_ADDING|) never reach the server: they stay on
  -- the native collector (see the routing gate in ins_complete()).
  local collect = (ctx and ctx.mode and collectors[ctx.mode]) or collect_keyword
  local items, truncated = collect(args)

  -- isIncomplete=true only when truncated: a full result lets the client filter
  -- locally; a partial one tells it to re-query as the prefix narrows.
  return { isIncomplete = truncated, items = items }
end

local server_capabilities = {
  completionProvider = {
    triggerCharacters = {},
    resolveProvider = false,
  },
}

--- `cmd` for vim.lsp.start. A function cmd runs the server in-process; the
--- returned table is its RPC surface.
--- @param dispatchers vim.lsp.rpc.Dispatchers
--- @return vim.lsp.rpc.Client
function M.cmd(dispatchers)
  local closing = false
  local next_id = 0
  local srv = {}

  function srv.request(method, params, callback)
    next_id = next_id + 1

    if method == 'initialize' then
      callback(nil, { capabilities = server_capabilities })
    elseif method == 'textDocument/completion' then
      async.run(function()
        return do_complete(params)
      end, function(err, result)
        if closing then
          return
        end
        if err then
          callback({ code = protocol.ErrorCodes.InternalError, message = tostring(err) }, nil)
        else
          callback(nil, result)
        end
      end)
    elseif method == 'shutdown' then
      callback(nil, nil)
    else
      callback(nil, nil)
    end

    return true, next_id
  end

  function srv.notify(method, _params)
    if method == 'exit' then
      closing = true
      dispatchers.on_exit(0, 0)
    end
    return true
  end

  function srv.is_closing()
    return closing
  end

  function srv.terminate()
    closing = true
  end

  return srv
end

M._do_complete = do_complete
M._keyword_prefix = keyword_prefix

return M
