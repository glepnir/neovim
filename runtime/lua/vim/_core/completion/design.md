# vim.completion Design

This document tracks the current Lua implementation and the next planned work.
It is implementation-facing on purpose: if the code and this file disagree, the
code should win and this file should be updated.

## Status

Current state:

- `completion.lua` owns the public API and per-buffer config.
- `source.lua` is a pure source registry plus spec validation.
- `engine.lua` owns runtime state, dispatch, batching, matching, presentation,
  and the current accept pipeline.
- The prefix path is implemented and does not maintain a permanent global merged
  truth.
- The fuzzy path is implemented with a lazy flat view rebuilt on demand.
- The private C API `nvim__show_pum(startcol, opts)` now exists in the core.
- API-owned popup frames now keep their visible items and selected index in C,
  and `nvim_select_popupmenu_item(..., false, false, {})` updates that
  selection through the popupmenu renderer path.
- The Lua engine still stages through `vim.fn.complete()` for now.
  Renderer-only presentation is not enabled by default until selection and
  accept plumbing stop depending on the `CompleteDonePre`/`CompleteDone`
  contract of builtin insert completion.

Not finished yet:

- `commitCharacters` acceptance path
- richer LuaLS type cleanup and full Luadoc coverage
- tests for multi-source flow, accept flow, and fuzzy

## Files

```text
runtime/lua/vim/_core/completion/
├── completion.lua   public API + per-buffer config
├── source.lua       source registry + spec validation
├── engine.lua       runtime + dispatch + matching + present + accept
└── log.lua          shared ring-buffer log
```

No further splitting is planned for v1.

## Principles

- Lua owns completion data, matching, sorting, cancellation, and lifecycle.
- C should own only the current visible popup frame and selection state.
- C should not own the full completion universe.
- Source authors implement `get(ctx, sink)` and stay unaware of coroutines,
  `seq`, or `vim.schedule`.
- The engine must stay responsive under slow, streaming, or very large sources.

## Public API

```lua
vim.completion.source.register(spec)
vim.completion.source.get()
vim.completion.enable(enable, buf, opts?)
vim.completion.is_enabled(buf)
vim.completion.trigger(opts?)
vim.completion.set_log_level(level)
vim.completion.get_log()
```

## Per-buffer Config

```lua
---@class vim.completion.BufConfig
---@field source_mode 'all'|'explicit'
---@field include table<integer, true>
---@field exclude table<integer, true>
---@field autotrigger boolean
---@field matcher 'prefix'|'fuzzy'
---@field mode 'insert'|'cmdline'
```

Stable semantics:

- `enable(true, buf)` -> all registered sources
- `enable(true, buf, { sources = {...} })`
  - explicit mode: additive include
  - all mode: un-exclude those sources
- `enable(false, buf, { sources = {...} })`
  - explicit mode: remove those sources
  - all mode: exclude those sources
- `enable(false, buf)` -> disable completion entirely for the buffer

## Source Contract

### SourceSpec

```lua
---@class vim.completion.SourceSpec
---@field name string
---@field priority? integer
---@field trigger_characters? string[]
---@field keyword_pattern? string
---@field min_prefix_len? integer
---@field refresh? 'always'|'if_incomplete'|'never'
---@field filter? 'engine'|'source'
---@field max_items? integer
---@field get fun(ctx: vim.completion.Context, sink: vim.completion.SourceSink): nil|fun()
---@field resolve? fun(item: vim.completion.Item, done: fun(err?, item?))
---@field execute? fun(ctx: vim.completion.ExecuteContext)
```

Important current rules:

- `get()` may return a cancel function.
- `refresh='never'` means continued typing only re-filters existing items.
- `refresh='if_incomplete'` redispatches only after `done({ incomplete = true })`.
- `refresh='always'` redispatches for continued typing inside the same anchor.
- `filter='engine'` means the engine indexes and filters the source items.
- `filter='source'` means the source returns a current filtered snapshot and the
  engine does not build a full index for that source.

### SourceSink

```lua
---@class vim.completion.SourceSink
---@field add fun(items: vim.completion.Item|vim.completion.Item[])
---@field replace fun(items: vim.completion.Item[])
---@field done fun(meta?: { incomplete?: boolean })
---@field fail fun(err: any)
```

Current behavior:

- `add()` appends into an adaptive batch owned by the engine.
- `replace()` clears prior items for the active request and installs a new
  snapshot.
- `done()` and `fail()` both end the active request and schedule presentation.

### Context

```lua
---@class vim.completion.Context
---@field bufnr integer
---@field cursor [integer, integer]
---@field line string
---@field prefix string
---@field startcol integer
---@field reason 'manual'|'keyword'|'trigger_character'
---@field trigger_character? string
---@field limit integer
---@field await fun(fn: fun(done: fun(...: any))): ...: any
---@field cancelled fun(): boolean
---@field on_cancel fun(fn: fun())
```

`limit` is important for large `filter='source'` sources.

### Item

```lua
---@class vim.completion.Item
---@field word string
---@field abbr? string
---@field kind? string
---@field menu? string
---@field info? string
---@field filterText? string
---@field sortText? string
---@field preselect? boolean
---@field dup? boolean
---@field icase? boolean
---@field commitCharacters? string[]
---@field user_data? any
---@field source_name? string
---@field _sort_key? string
---@field _match_score? number
```

Notes:

- `word` is the only required field.
- `user_data` belongs to the source payload and is not overwritten by the engine.
- `_sort_key` is the only constant engine-owned field.
- `_match_score` is temporary and fuzzy-only.
- `commitCharacters` is declared in the schema, but the acceptance behavior is
  still TODO and depends on the renderer API carrying current visible selection.

## Engine State

The current implementation uses module-local state rather than a large session
object graph:

```lua
attached
seq
session
active_specs
source_state[name]
state_ver
fuzzy_items
fuzzy_words
fuzzy_ver
visible_entries
completed_entry
present_pending
debounce_timer
deadline_timer
```

Per-source runtime state:

```lua
st = {
  spec = spec,
  req = 0,
  pending = false,
  cancel = nil,
  incomplete = false,
  startcol = 0,
  prefix = '',
  items = {},
  sorted_end = 0,
  version = 0,
  overflow = false,
}
```

Two request tokens are active:

- `seq` for the whole session
- `req` per source request inside the session

Every async callback must match both.

## Multi-source Flow

The current implementation is not the original permanent-merged-array design.

### 1. Build Plan

`build_plan()`:

1. Reads current line and cursor
2. Resolves enabled sources with the buffer filter
3. Computes `(startcol, prefix)` per source using that source's
   `keyword_pattern`
4. Picks the first eligible candidate in priority order as the popup anchor
5. Keeps only sources that share that same `startcol`

This is the current single-anchor rule:

- a popup has one column
- a session has one anchor
- source-local tokenization is still respected

### 2. Install Session

`install_session()`:

- resets runtime
- increments `seq`
- installs a new session snapshot
- creates a fresh `source_state` for each active source
- starts the deadline timer
- dispatches all active sources

### 3. Dispatch Source

`dispatch_source()`:

- increments the source-local `req`
- cancels any previous request for that same source
- constructs `sink.add/replace/done/fail`
- injects `await`, `cancelled`, and `on_cancel` into the context
- runs `spec.get()` inside `Async.run`

## Adaptive Batching

The current implementation still uses the original adaptive batch formula:

```lua
next_batch = clamp(count * (TIME_BUDGET_US / elapsed_us), MIN_BATCH, MAX_BATCH)
```

Constants:

```lua
TIME_BUDGET_US = 8000
INITIAL_BATCH  = 64
MIN_BATCH      = 16
MAX_BATCH      = 2048
```

Current `sink.add()` flow:

1. normalize item
2. append into the in-flight batch
3. once the batch threshold is reached:
   - publish the batch
   - update the next batch size from measured elapsed time
   - yield once through `Async.await(...)`

This keeps source authors unaware of coroutine machinery.

## Source Storage Modes

### `filter='engine'`

Indexed storage:

```lua
st.items       -- [1..sorted_end] sorted, tail unsorted
st.sorted_end
```

Current behavior:

- `add()` appends to the tail
- `ensure_sorted()` sorts only the tail
- sorted head and sorted tail are merged
- adjacent exact duplicates are removed

### `filter='source'`

Snapshot storage:

```lua
st.items       -- current source-provided result set
```

Current behavior:

- source owns large-universe filtering
- engine only narrows the current snapshot
- no per-source binary-search index is built

## Prefix Path

Prefix mode is the hot path.

Current implementation:

1. `collect_source_mode_items(prefix, limit)` narrows current snapshots
2. `collect_engine_mode_items(prefix, limit)`:
   - `ensure_sorted(st)` for each indexed source
   - binary-search `[lo, hi]` per source
   - k-way merge only the active ranges
3. concatenate both groups
4. display sort
5. trim to `candidate_limit()`

Important detail:

- prefix mode does **not** rebuild or keep a permanent global merged truth
- only the fuzzy path builds a temporary flat view

## Fuzzy Path

Current implementation:

1. if `fuzzy_ver ~= state_ver`, rebuild a lazy flat view from all active source
   items
2. build `fuzzy_words`
3. run `vim.fn.matchfuzzypos(fuzzy_words, prefix)`
4. map matched words back to items through lower-bound plus adjacent scan
5. set temporary `_match_score`
6. display sort

This is intentionally more expensive than prefix, but it is bounded by the
current source state rather than a permanent global cache.

## Presentation

Current presentation path:

```text
publish -> schedule_present() -> try_present() -> present_items()
```

`schedule_present()` coalesces updates into one scheduled pass.

### Current presenter behavior

`present_items(startcol, items)` currently does:

1. current default path: `vim.fn.complete(startcol + 1, matches)`
2. staged future path: `vim.api.nvim__show_pum(startcol, { items = items, selected = -1 })`
3. temporary compatibility path during migration: `vim.api.nvim__complete_show(...)`

This keeps the Lua implementation running while the private C API is still
being patched in.

## Target C API

The intended private renderer API is:

```c
nvim__show_pum(startcol, opts)
```

Where `opts` contains the current visible frame:

```lua
{
  items = { ... },
  selected = -1,
}
```

Behavior:

- `items ~= {}` -> show or update the popup
- `items == {}` -> hide the popup
- `nvim_select_popupmenu_item(..., false, false, {})` -> update selected index
  for API-owned popup frames

C-side responsibilities:

- keep the current visible popup frame
- keep the selected index
- drive redraw
- support `pumvisible()`, `CompleteChanged`, and selection queries used during
  `CompleteDonePre`

Lua-side responsibilities stay unchanged:

- source lifecycle
- batching
- incremental sort
- prefix range query
- fuzzy
- final display ordering

## Accept Flow

Current Lua accept path:

1. `CompleteDonePre` captures the selected entry while completion info is valid
2. `CompleteDone` reads `v:completed_item` and `v:event.reason`
3. if the item was accepted:
   - find the selected visible entry
   - run `resolve()` if the source provides it
   - run `execute()` if the source provides it
   - otherwise replace `[startcol, cursor)` with `item.word`
4. reset runtime

This flow is shared by the current fallback presenter and the planned renderer
API.

## `commitCharacters`

`commitCharacters` is part of the item schema, but the behavior is not wired yet.

Planned behavior:

1. popup is visible
2. a visible item is selected
3. `InsertCharPre` receives a typed character
4. if the selected item contains that character in `commitCharacters`:
   - accept the selected item first
   - then insert the typed character

Why this is coupled to the C API:

- it needs a reliable current selected index
- it needs stable visible-frame ownership outside `vim.fn.complete()` fallback
- it should behave the same for redraw, navigation, and accept

So `commitCharacters` should land together with or immediately after the
`nvim__show_pum(startcol, opts)` patch.

## Hard Bounds

Current bounds:

```lua
ENGINE_MAX_ITEMS = 10000
OVERSCAN         = 4
MIN_CANDIDATES   = 40
```

```lua
candidate_limit = max(pumheight * OVERSCAN, MIN_CANDIDATES)
```

Current consequences:

- prefix collection stops once enough candidates are gathered
- `filter='engine'` sources are capped by `max_items` or `ENGINE_MAX_ITEMS`
- `filter='source'` sources are expected to respect `ctx.limit`

These bounds are what make large user-defined sources survivable without making
the engine fully source-specific.

## Next TODO

Near-term next steps:

1. wire `engine.lua` from the current `vim.fn.complete()` staging path to
   `nvim__show_pum(startcol, opts)`
2. add the missing renderer-backed accept plumbing needed to replace
   `CompleteDonePre`/`CompleteDone`
3. implement `commitCharacters` on top of renderer-backed visible selection
4. continue Luadoc and LuaLS cleanup
5. add tests for:
   - source selection and single-anchor planning
   - per-source request versioning
   - adaptive sink batching
   - prefix range query
   - fuzzy lazy flat view
   - accept flow
   - `commitCharacters`
6. add cmdline support after insert-mode renderer behavior is stable

## Current Reality Check

The code is intentionally between two states:

- already much leaner and more correct than the original all-merged design
- not yet finished on renderer integration and diagnostics cleanup

That is okay. The important constraint is to keep the design doc aligned with
the real implementation while we finish the remaining C and polish work.
