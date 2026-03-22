--- @brief
--- The `vim.completion` module handles completion source collection in Lua.
--- Filtering, sorting, pum display, C-N/C-P navigation, C-Y/C-E, and
--- CompleteDone all stay in the existing C code (insexpand.c).
---
--- All sources — both builtin ('complete' option flags) and user-registered
--- — are collected through Lua via a single coroutine-based dispatcher.
---
--- # Sync vs async sources
---
--- Sources that never call `ctx.await()` (buffer scan, taglist, dict lookup)
--- run to completion inside the first coroutine resume — before `Async.run`
--- returns.  Their results are available immediately when the C caller
--- needs them (C-N/C-P sync path) and populate the initial popup.
---
--- Sources that do yield (LSP, user-registered async sources) deliver
--- results later via `vim.schedule`.  Those late deliveries trigger an
--- in-place popup refresh on the C side — because the popup dimensions
--- are locked at first display (see `pum_lock_dimensions` in
--- `popupmenu.c`), the refresh reuses the same grid and only updates
--- cell contents.  No resize, no flicker; a scrollbar appears if the
--- list outgrows the locked height.
---
--- # Timeouts
---
--- Each source has its own timeout budget (`spec.timeout`, defaults to
--- 1000ms for sync builtins, 5000ms for LSP).  Sources are dispatched
--- concurrently, so the slowest one's timeout bounds the whole session.
--- There is no separate session-level deadline.

--- @class vim.completion.EnableOpts
--- @field sources? vim.completion.SourceHandle[]
--- @field autotrigger? boolean Default `true`.
--- @field mode? 'insert'|'cmdline' Default `'insert'`.

--- @class vim.completion.SourceFilter
--- @field include? table<integer, true>
--- @field exclude? table<integer, true>

local Async = require('vim._async')
local source = require('vim._core.completion.source')
local log = require('vim._core.completion.log')

-- ---------------------------------------------------------------------------
-- Per-buffer config
-- ---------------------------------------------------------------------------

--- @class vim.completion.BufConfig
--- @field source_mode 'all'|'explicit'
--- @field include table<integer, true>
--- @field exclude table<integer, true>
--- @field autotrigger boolean
--- @field mode 'insert'|'cmdline'

--- @type table<integer, vim.completion.BufConfig>
local buf_config = {}

--- @type integer?
local cleanup_augroup = nil

local function ensure_cleanup()
  if cleanup_augroup then
    return
  end
  cleanup_augroup = vim.api.nvim_create_augroup('vim.completion', { clear = true })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = cleanup_augroup,
    callback = function(ev)
      buf_config[ev.buf] = nil
    end,
  })
end

--- @param set table<any, any>
--- @return boolean
local function has_items(set)
  return next(set) ~= nil
end

--- @param sources vim.completion.SourceHandle[]
local function validate_sources(sources)
  vim.validate('opts.sources', sources, 'table')
  for i, src in ipairs(sources) do
    if type(src) ~= 'table' or not src._id then
      error(('opts.sources[%d]: expected SourceHandle'):format(i))
    end
  end
end

--- @param mode string
local function validate_mode(mode)
  if mode ~= 'insert' and mode ~= 'cmdline' then
    error(("opts.mode: expected 'insert' or 'cmdline', got %q"):format(mode))
  end
end

--- @param bufnr integer
--- @return vim.completion.SourceFilter?
local function build_source_filter(bufnr)
  local cfg = buf_config[bufnr]
  if not cfg then
    return nil
  end
  local filter = {} --- @type vim.completion.SourceFilter
  if cfg.source_mode == 'all' then
    if has_items(cfg.exclude) then
      filter.exclude = vim.deepcopy(cfg.exclude)
    end
  else
    filter.include = vim.deepcopy(cfg.include)
  end
  return filter
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- @param timer uv.uv_timer_t?
local function stop_timer(timer)
  if timer then
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end
end

--- @param items vim.completion.Item|vim.completion.Item[]
--- @return vim.completion.Item[]
local function as_item_list(items)
  if type(items) == 'table' and items.word ~= nil then
    return {
      items --[[@as vim.completion.Item]],
    }
  end
  return items --[[@as vim.completion.Item[] ]]
end

-- ---------------------------------------------------------------------------
-- Source resolution
-- ---------------------------------------------------------------------------

--- @class vim.completion.ResolvedSource
--- @field spec vim.completion.SourceSpec
--- @field cpt_index integer  0-based index into C cpt_sources_array

--- Resolve all sources: builtin (from 'complete' option) + user-registered.
--- Each entry carries a `cpt_index` that maps to the C-side cpt_sources_array
--- so that per-source startcol / max_matches work correctly.
--- cpt sources get indices 0..N-1, non-cpt sources get N, N+1, ...
--- (the C side grows cpt_sources_array dynamically as needed).
--- @param bufnr integer
--- @return vim.completion.ResolvedSource[]
local function resolve_all_sources(bufnr)
  local cpt = vim.opt_local.complete:get() --[[@as string[] ]]
  local cpt_specs = source.resolve_cpt(cpt)

  local resolved = {} --- @type vim.completion.ResolvedSource[]
  local next_idx = 0
  for _, spec in ipairs(cpt_specs) do
    resolved[#resolved + 1] = { spec = spec, cpt_index = next_idx }
    next_idx = next_idx + 1
  end

  local filter = build_source_filter(bufnr)
  for _, spec in ipairs(source.resolve(filter)) do
    resolved[#resolved + 1] = { spec = spec, cpt_index = next_idx }
    next_idx = next_idx + 1
  end

  return resolved
end

-- ---------------------------------------------------------------------------
-- Per-source cancellation registry
-- ---------------------------------------------------------------------------

--- @type table<string, uv.uv_timer_t>
local source_timers = {}
--- @type table<string, fun()>
local source_cancelers = {}

local function cancel_all_sources()
  for name, cancel in pairs(source_cancelers) do
    pcall(cancel)
    source_cancelers[name] = nil
  end
  for name, timer in pairs(source_timers) do
    stop_timer(timer)
    source_timers[name] = nil
  end
end

-- ---------------------------------------------------------------------------
-- Context builder
-- ---------------------------------------------------------------------------

--- @param line string
--- @param col integer     0-based compl_col
--- @param cursor_col integer  0-based
--- @param bufnr integer
--- @return vim.completion.Context
local function make_context(line, col, cursor_col, bufnr)
  local prefix = line:sub(col + 1, cursor_col)
  return {
    bufnr = bufnr,
    cursor = vim.api.nvim_win_get_cursor(0),
    line = line,
    prefix = prefix,
    startcol = col,
    reason = 'keyword',
    trigger_character = nil,
    limit = 1000,
    await = function(_) end,
    cancelled = function()
      return false
    end,
    on_cancel = function(_) end,
  }
end

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

--- Dispatch one source.
---
--- The source's `get()` runs inside a coroutine.  Sources that never call
--- `ctx.await()` complete within the first resume — before `Async.run`
--- returns — so their results are available immediately when the C caller
--- needs them (C-N/C-P sync path) and populate the initial popup.
---
--- Sources that *do* yield will deliver results later via `vim.schedule`.
--- Those late deliveries trigger an in-place popup refresh on the C side.
--- Because popup dimensions are locked at first display, the refresh
--- updates contents only — no resize flicker.  See `pum_lock_dimensions`
--- in `popupmenu.c` and the `pum_visible()` refresh branch in
--- `ins_compl_add_items`.
---
--- `ctx.cancelled()` reports whether this source has been cancelled
--- (session end, per-source timeout, or user key cancellation); source
--- authors are expected to check it periodically in long-running loops
--- or between `await` calls.
---
--- @param rsrc vim.completion.ResolvedSource
--- @param ctx vim.completion.Context
--- @param ticket integer
local function dispatch(rsrc, ctx, ticket)
  local spec = rsrc.spec
  local cpt_index = rsrc.cpt_index
  local cancelled = false
  local finished = false

  --- @return boolean
  local function is_stale()
    return cancelled
  end

  -- Per-source timeout ------------------------------------------------------
  -- Each source has its own timeout budget (default 1000ms for sync
  -- builtins, 5000ms for LSP).  No separate session-level deadline —
  -- per-source is enough because sources are dispatched concurrently,
  -- so the slowest one's timeout bounds the whole session too.
  stop_timer(source_timers[spec.name])
  source_timers[spec.name] = nil
  local timeout_ms = spec.timeout or 5000
  local timer = vim.uv.new_timer()
  if timer then
    source_timers[spec.name] = timer
    timer:start(
      timeout_ms,
      0,
      vim.schedule_wrap(function()
        source_timers[spec.name] = nil
        if not cancelled then
          cancelled = true
          local cancel = source_cancelers[spec.name]
          if cancel then
            pcall(cancel)
            source_cancelers[spec.name] = nil
          end
          log.warn('source %q timed out after %dms', spec.name, timeout_ms)
        end
      end)
    )
  end

  Async.run(function() --- @async
    local cleanup = {} --- @type fun()[]
    -- Per-source startcol.  -3 = use session's compl_col (default).
    -- A source can override this via sink.set_startcol() before or
    -- during sink.add() calls, e.g. LSP sources set it from
    -- textEdit.range.start.character.
    local source_startcol = -3

    --- Push items to C.  Synchronous — no yielding.  Long-running sources
    --- that want to interleave with other work should yield explicitly via
    --- `ctx.await(vim.schedule)` between batches; the framework does not
    --- inject yields into sink.add because doing so turns a single logical
    --- delivery into several smaller ones, and every delivery after the
    --- PUM is visible is kept invisible until the user scrolls — so the
    --- items would just pile up without the user seeing incremental
    --- progress anyway.
    --- @param list vim.completion.Item[]
    local function push(list)
      if #list == 0 then
        return
      end
      vim.api.nvim__compl_add({
        ticket = ticket,
        source_idx = cpt_index,
        startcol = source_startcol,
        items = list,
      })
    end

    local sink = {
      --- Add completion items.
      --- @param items vim.completion.Item|vim.completion.Item[]
      add = function(items)
        if is_stale() then
          return
        end
        push(as_item_list(items))
      end,
      replace = function(items)
        if is_stale() then
          return
        end
        push(items)
      end,
      --- Set the start column for this source (0-based byte offset).
      --- Must be called before sink.add().  Maps to
      --- cpt_sources_array[cpt_index].cs_startcol on the C side, which
      --- also auto-prepends line[compl_col..startcol] to each item's
      --- word so the popup stays anchored at compl_col.
      --- @param col integer
      set_startcol = function(col)
        source_startcol = col
      end,
      done = function(_)
        if is_stale() or finished then
          return
        end
        finished = true
        stop_timer(source_timers[spec.name])
        source_timers[spec.name] = nil
        source_cancelers[spec.name] = nil
      end,
      fail = function(err)
        if is_stale() or finished then
          return
        end
        finished = true
        stop_timer(source_timers[spec.name])
        source_timers[spec.name] = nil
        source_cancelers[spec.name] = nil
        log.warn('source %q error: %s', spec.name, err)
      end,
    }

    local async_ctx = {
      bufnr = ctx.bufnr,
      cursor = ctx.cursor,
      line = ctx.line,
      prefix = ctx.prefix,
      startcol = ctx.startcol,
      reason = ctx.reason,
      trigger_character = ctx.trigger_character,
      limit = ctx.limit,
      await = function(fn)
        return Async.await(1, fn)
      end,
      cancelled = is_stale,
      on_cancel = function(fn)
        cleanup[#cleanup + 1] = fn
      end,
    }

    local ok, cancel_or_err = pcall(spec.get, async_ctx, sink)

    local function combined_cancel()
      cancelled = true
      for _, fn in ipairs(cleanup) do
        pcall(fn)
      end
      if ok and type(cancel_or_err) == 'function' then
        pcall(cancel_or_err)
      end
    end

    if not is_stale() then
      source_cancelers[spec.name] = combined_cancel
    else
      combined_cancel()
      return
    end

    if not ok then
      sink.fail(cancel_or_err)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- _get_matches: called from C via NLUA_EXEC_STATIC
-- ---------------------------------------------------------------------------

--- ctrl_x_mode constants (must match insexpand.c enum).
local CTRL_X_NORMAL = 0
local CTRL_X_WHOLE_LINE = 3
local CTRL_X_FILES = 4
local CTRL_X_TAGS = 261 -- 5 + 0x100
local CTRL_X_DICTIONARY = 265 -- 9 + 0x100
local CTRL_X_THESAURUS = 266 -- 10 + 0x100
local CTRL_X_CMDLINE = 11
local CTRL_X_SPELL = 14
local CTRL_X_EVAL = 16
local CTRL_X_BUFNAMES = 18

--- Map ctrl_x_mode → builtin source name(s) to dispatch.
--- nil = dispatch all sources (CTRL_X_NORMAL).
--- @type table<integer, string[]>
local ctrl_x_source_map = {
  [CTRL_X_FILES] = { 'filepath' },
  [CTRL_X_TAGS] = { 'cpt_t' },
  [CTRL_X_DICTIONARY] = { 'cpt_k' },
  [CTRL_X_THESAURUS] = { 'cpt_s' },
  [CTRL_X_BUFNAMES] = { 'cpt_f' },
  [CTRL_X_WHOLE_LINE] = { 'cpt_.' }, -- TODO: proper whole-line source
  -- CTRL_X_SPELL, CTRL_X_CMDLINE: not yet implemented
}

--- Entry point from C `ins_compl_get_exp()`.
---
--- @param pattern string    compl_pattern
--- @param col integer       compl_col (0-based)
--- @param ticket integer    compl_ticket for state sync
--- @param ctrl_x integer    ctrl_x_mode
local function get_matches(pattern, col, ticket, ctrl_x)
  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_get_current_line()
  local cursor_col = vim.api.nvim_win_get_cursor(0)[2]

  -- Cancel any in-flight work from the previous session.
  cancel_all_sources()

  local ctx = make_context(line, col, cursor_col, bufnr)

  -- For specific ctrl_x modes (C-x C-f, C-x C-t, etc.), dispatch only
  -- the relevant source(s) looked up by name — they might not be in
  -- the user's 'complete' option.
  local wanted = ctrl_x_source_map[ctrl_x]
  if wanted then
    ctx.pattern = pattern
    local idx = 0
    for _, name in ipairs(wanted) do
      local spec = source.get_by_name(name)
      if spec then
        dispatch({ spec = spec, cpt_index = idx }, ctx, ticket)
        idx = idx + 1
      end
    end
    return
  end

  -- CTRL_X_NORMAL (C-N/C-P): dispatch all cpt + registered sources.
  local resolved = resolve_all_sources(bufnr)
  if #resolved == 0 then
    return
  end

  for _, rsrc in ipairs(resolved) do
    dispatch(rsrc, ctx, ticket)
  end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

local M = {}

M.source = {
  add = source.add,
  get = source.get,
}

--- Enable or disable completion for a buffer.
---
--- @param enable boolean
--- @param buf integer Buffer handle, 0 for current.
--- @param opts? vim.completion.EnableOpts
function M.enable(enable, buf, opts)
  buf = vim._resolve_bufnr(buf)
  ensure_cleanup()

  if opts ~= nil then
    vim.validate('opts', opts, 'table')
    if opts.sources then
      validate_sources(opts.sources)
    end
    if opts.autotrigger ~= nil then
      vim.validate('opts.autotrigger', opts.autotrigger, 'boolean')
    end
    if opts.mode ~= nil then
      validate_mode(opts.mode)
    end
  end

  if not enable then
    local cfg = buf_config[buf]
    if not cfg then
      return
    end
    if opts and opts.sources then
      if cfg.source_mode == 'all' then
        for _, src in ipairs(opts.sources) do
          cfg.exclude[src._id] = true
        end
      else
        for _, src in ipairs(opts.sources) do
          cfg.include[src._id] = nil
        end
      end
      if cfg.source_mode == 'explicit' and not has_items(cfg.include) then
        buf_config[buf] = nil
      end
    else
      buf_config[buf] = nil
    end
    return
  end

  local cfg = buf_config[buf]
  if not cfg then
    cfg = {
      source_mode = opts and opts.sources and 'explicit' or 'all',
      include = {},
      exclude = {},
      autotrigger = true,
      mode = 'insert',
    }
    buf_config[buf] = cfg
  end

  if opts then
    if opts.autotrigger ~= nil then
      cfg.autotrigger = opts.autotrigger
    end
    if opts.mode ~= nil then
      cfg.mode = opts.mode
    end
  end

  if opts == nil then
    cfg.source_mode = 'all'
    cfg.include = {}
    cfg.exclude = {}
  elseif opts.sources then
    if cfg.source_mode == 'all' then
      for _, src in ipairs(opts.sources) do
        cfg.exclude[src._id] = nil
      end
    else
      for _, src in ipairs(opts.sources) do
        cfg.include[src._id] = true
      end
    end
  end
end

--- @param buf integer
--- @return boolean
function M.is_enabled(buf)
  buf = vim._resolve_bufnr(buf)
  return buf_config[buf] ~= nil
end

--- Force-trigger completion.
--- @param _opts? { sources?: vim.completion.SourceHandle[] }
function M.trigger(_opts)
  -- TODO: manual trigger
end

--- @param level 'trace'|'debug'|'info'|'warn'|'error'
function M.set_log_level(level)
  log.set_level(level)
end

--- @return string[]
function M.get_log()
  return log.get()
end

--- Entry point from C.
--- @nodoc
function M._get_matches(...)
  return get_matches(...)
end

--- Called from C `ins_compl_free()` when a session ends (accept, cancel,
--- Escape, mode change, etc.).  Cancels in-flight source work so slow
--- sources (LSP requests, timers, coroutines) don't keep running past
--- the session they were dispatched for.
---
--- The ticket bump on the C side already guarantees correctness (stale
--- deliveries are dropped by the ticket check in ins_compl_add_items);
--- this hook is purely to stop wasted work.
---
--- @nodoc
--- @param _old_ticket integer  The ticket of the ending session.
function M._on_session_end(_old_ticket)
  cancel_all_sources()
end

--- @nodoc
function M._clear()
  cancel_all_sources()
  buf_config = {}
  source._clear()
  log.clear()
  if cleanup_augroup then
    vim.api.nvim_del_augroup_by_id(cleanup_augroup)
    cleanup_augroup = nil
  end
end

return M
