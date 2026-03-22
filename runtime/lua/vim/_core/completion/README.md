# vim.completion

Implementation-tracking notes now live in [`design.md`](./design.md). This
README stays as a shorter overview.

Minimal asynchronous completion engine for Neovim.

## Files

```text
runtime/lua/vim/_core/completion/
├── completion.lua   public API + per-buffer config
├── source.lua       source registry + spec validation
├── engine.lua       runtime + dispatch + matching + present + accept
└── log.lua          shared ring-buffer log
```

4 files. No further splitting.

## Principles

- Lua owns completion data, matching, sorting, cancellation, and session lifecycle.
- C owns only the current visible pum frame: render, select, `CompleteChanged`.
- C does not hold a full completion list. No `compl_T`. No filter or sort in C.
- Item schema is minimal and editor-generic. No LSP concepts leak into engine.
- Source authors write `get(ctx, sink)`. They do not touch `vim._async`, `vim.schedule`, coroutines, or `seq`.
- The engine must stay responsive under large or slow sources. Budgeting and cancellation are part of the design.

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

- `enable(true, buf)` -> `all` mode
- `enable(true, buf, { sources = {...} })` -> explicit-mode additive / all-mode un-exclude
- `enable(false, buf, { sources = {...} })` -> explicit-mode remove / all-mode exclude
- `enable(false, buf)` -> disable entirely

## Source Contract

### SourceSpec

```lua
---@class vim.completion.SourceSpec
---@field name string
---@field priority? integer
---@field trigger_characters? string[]
---@field keyword_pattern? string                     -- default \k\+
---@field min_prefix_len? integer                    -- default 0
---@field refresh? 'always'|'if_incomplete'|'never'  -- default 'always'
---@field filter? 'engine'|'source'                  -- default 'engine'
---@field max_items? integer                         -- engine mode only
---@field get fun(ctx: Context, sink: SourceSink): nil|fun()
---@field resolve? fun(item: Item, done: fun(err?, item?))
---@field execute? fun(ctx: ExecuteContext)
```

- `get()` returns an optional cancel function.
- `refresh='never'`: engine re-filters existing items on continued typing.
- `refresh='if_incomplete'`: re-dispatch only if source reported `incomplete=true`.
- `refresh='always'`: re-dispatch on every new valid prefix inside the same anchor.
- `filter='engine'`: engine indexes and filters the source's items.
- `filter='source'`: source returns a current filtered snapshot; engine does not build a full index for it.

### SourceSink

```lua
---@class vim.completion.SourceSink
---@field add fun(items: Item|Item[])
---@field replace fun(items: Item[])
---@field done fun(meta?: { incomplete?: boolean })
---@field fail fun(err: any)
```

- `add()` supports one item or a batch. The engine handles adaptive yielding.
- `replace()` clears prior items for this request and installs a new snapshot.
- `done()` marks the request finished.
- `fail()` marks the request finished with error.

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

- `limit` tells large sources how many candidates the engine currently needs.
- `await()` bridges callback-style async APIs.
- `cancelled()` and `on_cancel()` let sources stop obsolete work.

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
---@field user_data? any
---@field source_name? string
---@field _sort_key? string
---@field _match_score? number
```

- `word` is required.
- `user_data` belongs to the source payload. The engine never overwrites it.
- `_sort_key` is the only constant internal field.
- `_match_score` is temporary and fuzzy-only.

## Engine Model

### Single PUM Anchor

A single popup has one `col`, so one session has one anchor.

Dispatch computes `(startcol, prefix)` per source from its own `keyword_pattern`.
The highest-priority eligible source chooses the session anchor. Only sources with
that same `startcol` participate in the session.

This keeps per-source tokenization while respecting one popup position.

### Session Identity

Two tokens are used:

- `seq`: global session generation
- `req`: per-source request id inside the session

Every callback checks both. This prevents stale results from older sessions and
older requests of the same source.

### Source Modes

#### `filter='engine'`

The engine stores one flat array per source:

```lua
st.items       -- [1..sorted_end] sorted, tail unsorted
st.sorted_end
```

Only the new tail is sorted on publish. Then the tail is merged into the sorted
head.

#### `filter='source'`

The engine keeps only the source's latest filtered snapshot:

```lua
st.items       -- current source-provided result set
```

No global index is built for that source. Continued typing can still narrow the
snapshot in-engine, but large universe filtering stays source-side.

### Hard Bounds

```lua
TIME_BUDGET_US   = 8000
ENGINE_MAX_ITEMS = 10000
OVERSCAN         = 4
MIN_CANDIDATES   = 40
```

```lua
candidate_limit = max(pumheight * OVERSCAN, MIN_CANDIDATES)
```

- Prefix collection stops once `candidate_limit` results are gathered.
- `engine` sources are capped by `max_items` or `ENGINE_MAX_ITEMS`.
- `source` sources are capped by `ctx.limit`.

These bounds are what keep the engine responsive under unknown source sizes.

## Trigger Model

### `InsertCharPre`

Only handles trigger characters:

```text
trigger_character -> debounce 15ms -> dispatch_new()
```

The trigger anchor is captured before insertion and reused after debounce.

### `TextChangedI`

Handles normal typing, backspace, paste, and undo.

```text
1. Re-read line/cursor.
2. Recompute current source candidates.
3. If no session and there is an eligible source -> debounce 30ms -> dispatch_new()
4. If the anchor changed -> dispatch_new()
5. Else:
   - refilter existing data immediately
   - refresh only sources with refresh='always' or incomplete=true
```

### `InsertLeave`

Cancel requests and hide the popup.

### `CompleteDone`

Resolve item, then execute or apply default insertion, then cancel the session.

## Accept Path

The accept path uses the existing completion autocmd contract:

1. `CompleteDonePre` captures the selected popup index while `complete_info()` is still valid
2. `CompleteDone` reads `v:completed_item` and `v:event.reason`
3. if the completion was accepted:
   - resolve the selected item if the source provides `resolve()`
   - call `execute()` if the source provides it
   - otherwise apply the default `word` insertion
4. reset the current session

This lets the temporary Lua presenter and the future renderer-only C API share
one acceptance pipeline.

## Prefix Path

Prefix mode does not maintain a permanent global merged truth.

For each present cycle:

1. `engine` sources: `ensure_sorted()`, then binary-search `[lo, hi]`
2. `source` sources: use their current snapshot
3. k-way merge only the current matching ranges
4. Stop at `candidate_limit`
5. `display_sort()` the collected candidates
6. show the popup

This avoids rebuilding a full global merged array on every source delivery.

### Complexity

For `k` indexed sources:

```text
O(sum(log N_i) + candidate_limit * k + candidate_limit log candidate_limit)
```

## Fuzzy Path

Fuzzy is lazy.

Only when matcher=`'fuzzy'` and source state changed does the engine rebuild a
flat fuzzy view:

```lua
fuzzy_items
fuzzy_words
```

Matching then uses:

```lua
vim.fn.matchfuzzypos(fuzzy_words, prefix)
```

The result is mapped back to items with binary search plus adjacent scan.

## Sorting and Dedup

### Prefix display sort

```text
preselect
> source priority
> exact filter text == prefix
> shorter word
> sortText
> _sort_key
> source registration order
> word
```

### Fuzzy display sort

```text
preselect
> source priority
> _match_score
> shorter word
> sortText
> _sort_key
> source registration order
> word
```

### Dedup

- Across sources: none
- Within one source: only exact duplicates are removed
- `dup=true` opts out of dedup

Exact duplicate key:

```text
(_sort_key, word)
```

## Renderer API

The private renderer API is:

```c
void nvim__show_pum(Integer startcol, Dict(show_pum) *opts, Error *err);
```

Where `opts` contains:

```lua
{
  items = { ... },
  selected = -1,
}
```

- `items` non-empty -> show or update popup
- `items` empty -> hide popup
- C owns only the currently visible popup frame and its selected index
- Lua continues to own source lifecycle, matching, sorting, and cancellation

The core API now exists in `api/vim.c`. The Lua engine still stages through
`vim.fn.complete()` by default until renderer-backed selection and accept flow
are fully wired.

## Implementation Order

1. Prefix-only v1 in `engine.lua`
2. Accept / resolve / execute
3. Fuzzy path
4. `nvim__show_pum` C patch
5. Cmdline support
6. Tests
