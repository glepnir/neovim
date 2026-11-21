---@diagnostic disable: no-unknown
local t = require('test.testutil')
local t_lsp = require('test.functional.plugin.lsp.testutil')
local n = require('test.functional.testnvim')()

local describe, it, before_each, after_each = t.describe, t.it, t.before_each, t.after_each
local clear = n.clear
local eq = t.eq
local eq_partial = t.eq_partial
local neq = t.neq
local exec_lua = n.exec_lua
local feed = n.feed
local retry = t.retry
local Screen = require('test.functional.ui.screen')

local create_server_definition = t_lsp.create_server_definition

local function completion_match(overrides)
  return vim.tbl_extend('force', {
    abbr_hlgroup = '',
    dup = 1,
    empty = 1,
    icase = 1,
    info = '',
    menu = '',
  }, overrides)
end

--- Convert completion results.
---
---@param line string line contents. Mark cursor position with `|`
---@param candidates lsp.CompletionList|lsp.CompletionItem[]
---@param lnum? integer 0-based, defaults to 0
---@return {items: table[]}
local function complete(line, candidates, lnum)
  lnum = lnum or 0
  -- nvim_win_get_cursor returns 0 based column, line:find returns 1 based
  local cursor_col = line:find('|') - 1
  line = line:gsub('|', '')
  return exec_lua(function(result)
    local line_to_cursor = line:sub(1, cursor_col)
    local compl_col = vim.fn.match(line_to_cursor, '\\k*$')
    local items = require('vim.lsp.completion')._lsp_to_complete_items(
      result,
      line,
      compl_col,
      cursor_col,
      1,
      lnum,
      'utf-16'
    )
    return {
      items = items,
    }
  end, candidates)
end

--- What the menu shows once the converted results are handed to the engine,
--- which filters them by what is typed.
---@param line string line contents. Mark cursor position with `|`
---@param candidates lsp.CompletionList|lsp.CompletionItem[]
---@return {abbr: string, word: string}[]
local function shown(line, candidates)
  local cursor_col = line:find('|') - 1
  line = line:gsub('|', '')
  n.api.nvim_buf_set_lines(0, 0, -1, true, { line })
  if cursor_col == #line then
    feed('A')
  else
    n.api.nvim_win_set_cursor(0, { 1, cursor_col })
    feed('i')
  end
  local got = exec_lua(function(result)
    local compl_col = vim.fn.match(line:sub(1, cursor_col), '\\k*$')
    local items = require('vim.lsp.completion')._lsp_to_complete_items(
      result,
      line,
      compl_col,
      cursor_col,
      1,
      0,
      'utf-16'
    )
    local cot = vim.o.completeopt
    vim.opt.completeopt:append({ 'menuone', 'noselect' })
    local id = #items > 0 and vim.api.nvim__complete({ col = compl_col + 1, items = items }) or 0
    local matches = id > 0 and vim.fn.complete_info({ 'matches' }).matches or {}
    if id > 0 then
      vim.api.nvim__complete({ id = id })
    end
    vim.o.completeopt = cot
    return vim.tbl_map(function(m)
      return { abbr = m.abbr, word = m.word }
    end, matches)
  end, candidates)
  feed('<Esc>')
  return got
end

--- Wait for pumvisible() to equal `visible` (default 1)
---@param visible? integer 1 to wait for pum shown, 0 to wait for pum hidden
local function wait_for_pum(visible)
  visible = visible == nil and 1 or visible
  retry(nil, nil, function()
    eq(
      visible,
      exec_lua(function()
        return vim.fn.pumvisible()
      end)
    )
  end)
end

--- The 'preinsert' preview, which is virtual text rather than buffer content.
---
--- Errors when the module that draws it never ran, so that a missing preview
--- and a missing namespace do not look the same.
---@return string? nil when nothing is previewed
local function preview_text()
  return exec_lua(function()
    local ns = assert(
      vim.api.nvim_get_namespaces()['nvim.completion.preinsert'],
      "the 'preinsert' preview module has not run"
    )
    local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })
    if #marks == 0 then
      return nil
    end
    assert(#marks == 1, 'more than one preview')
    return marks[1][4].virt_text[1][1]
  end)
end

--- Detach client and assert the pum no longer appears.
---@param client_id integer
local function assert_cleanup_after_detach(client_id)
  feed('<Esc>o')
  exec_lua(function()
    vim.lsp.completion.get()
  end)
  wait_for_pum(1)
  feed('<C-e>')

  -- Detach then re-trigger under identical conditions.
  exec_lua(function()
    vim.lsp.buf_detach_client(0, client_id)
  end)
  exec_lua(function()
    vim.lsp.completion.get()
  end)
  wait_for_pum(0)
  feed('<Esc>')
end

describe('vim.lsp.completion: item conversion', function()
  before_each(n.clear)

  -- https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_completion
  it('prefers textEdit over label as word', function()
    n.command('set completeopt=menuone,popup')
    local range0 = {
      start = { line = 0, character = 0 },
      ['end'] = { line = 0, character = 0 },
    }
    local completion_list = {
      -- resolves into label
      { label = 'foobar', sortText = 'a', documentation = 'documentation' },
      {
        label = 'foobar',
        sortText = 'b',
        documentation = { value = 'documentation' },
      },
      -- resolves into insertText
      { label = 'foocar', sortText = 'c', insertText = 'foobar' },
      { label = 'foocar', sortText = 'd', insertText = 'foobar' },
      -- resolves into textEdit.newText
      {
        label = 'foocar',
        sortText = 'e',
        insertText = 'foodar',
        textEdit = { newText = 'foobar', range = range0 },
      },
      { label = 'foocar', sortText = 'f', textEdit = { newText = 'foobar', range = range0 } },
      -- plain text
      {
        label = 'foocar',
        sortText = 'g',
        insertText = 'foodar(${1:var1})',
        insertTextFormat = 1,
      },
      {
        label = '•INT16_C(c)',
        insertText = 'x$0',
        insertTextFormat = 2,
        filterText = 'INT16_C',
        sortText = 'h',
        textEdit = {
          newText = 'INT16_C(${1:c})',
          range = range0,
        },
      },
      -- "" is unset
      {
        label = 'zoocar_long',
        sortText = '',
        insertText = '',
        insertTextFormat = 2,
        textEdit = { newText = 'foobar($1)', range = range0 },
      },
    }
    local expected = {
      { abbr = 'foobar', word = 'foobar' },
      { abbr = 'foobar', word = 'foobar' },
      { abbr = 'foocar', word = 'foobar' },
      { abbr = 'foocar', word = 'foobar' },
      { abbr = 'foocar', word = 'foobar' },
      { abbr = 'foocar', word = 'foobar' },
      { abbr = 'foocar', word = 'foodar(${1:var1})' }, -- marked as PlainText, text is used as is
      { abbr = '•INT16_C(c)', word = 'INT16_C' },
      { abbr = 'zoocar_long', word = 'foobar' },
    }
    local result = complete('|', completion_list)
    eq_partial(expected, result.items)
    eq('```\nINT16_C(c)\n```', result.items[8].info)
  end)

  local word_sorter = function(a, b)
    return a.word > b.word
  end

  it('does not filter if there is a textEdit', function()
    local range0 = {
      start = { line = 0, character = 0 },
      ['end'] = { line = 0, character = 0 },
    }
    local completion_list = {
      { label = 'foo', textEdit = { newText = 'foo', range = range0 } },
      { label = 'bar', textEdit = { newText = 'bar', range = range0 } },
    }
    local result = complete('fo|', completion_list)
    local expected = {
      { abbr = 'foo', word = 'foo' },
    }
    local got = result.items
    table.sort(expected, word_sorter)
    table.sort(got, word_sorter)
    eq_partial(expected, got)
  end)

  it('generate "■" symbol with highlight group for CompletionItemKind.Color', function()
    local completion_list = {
      { label = 'text-red-300', kind = 16, documentation = 'color: rgb(252, 165, 165)' },
    }
    local result = complete('|', completion_list)
    eq_partial(
      { { word = 'text-red-300', kind_hlgroup = '@lsp.color.fca5a5', kind = '■' } },
      result.items
    )
  end)

  it('uses labelDetails for abbr and menu', function()
    local completion_list = {
      {
        label = 'printf',
        kind = 3,
        detail = 'int',
        sortText = '1',
        labelDetails = { detail = '(const char *restrict, ...)', description = 'stdio.h' },
      },
      {
        label = ' flush',
        kind = 2,
        insertText = 'flush()',
        insertTextFormat = 2,
        filterText = 'flush',
        sortText = '2',
        labelDetails = { detail = '()' },
      },
    }
    local result = complete('|', completion_list)
    eq('printf(const char *restrict, ...)', result.items[1].abbr)
    eq('stdio.h', result.items[1].menu)
    eq('flush', result.items[2].word)
  end)

  ---@param prefix string
  ---@param items lsp.CompletionItem[]
  ---@param expected table[]
  local assert_completion_matches = function(prefix, items, expected)
    local got = shown(prefix .. '|', items)
    table.sort(expected, word_sorter)
    table.sort(got, word_sorter)
    eq_partial(expected, got)
  end

  it('filters by filterText while inserting the edit text', function()
    local items = {
      {
        filterText = '<module',
        insertTextFormat = 2,
        kind = 10,
        label = 'module',
        sortText = 'module',
        textEdit = {
          newText = '<module>$1</module>$0',
          range = {
            start = { character = 0, line = 0 },
            ['end'] = { character = 0, line = 0 },
          },
        },
      },
      {
        filterText = 'atto',
        insertTextFormat = 1,
        kind = 7,
        label = '•std::atto',
        sortText = 'atto',
        textEdit = {
          newText = 'std::atto',
          range = {
            start = { character = 0, line = 0 },
            ['end'] = { character = 0, line = 0 },
          },
        },
      },
      {
        filterText = 'adopt_lock_t',
        insertTextFormat = 1,
        kind = 7,
        label = '•std::adopt_lock_t',
        sortText = 'adopt_lock_t',
        insertText = 'std::adopt_lock_t',
      },
    }
    assert_completion_matches('<mo', items, {
      { abbr = 'module', word = 'module' },
    })
    assert_completion_matches('a', items, {
      { abbr = '•std::atto', word = 'std::atto' },
      { abbr = '•std::adopt_lock_t', word = 'std::adopt_lock_t' },
    })
    assert_completion_matches('', items, {
      { abbr = 'module', word = 'module' },
      { abbr = '•std::atto', word = 'std::atto' },
      { abbr = '•std::adopt_lock_t', word = 'std::adopt_lock_t' },
    })
  end)

  describe('when completeopt has fuzzy matching enabled', function()
    before_each(function()
      exec_lua(function()
        vim.opt.completeopt:append('fuzzy')
      end)
    end)
    after_each(function()
      exec_lua(function()
        vim.opt.completeopt:remove('fuzzy')
      end)
    end)

    it('fuzzy matches on filterText', function()
      assert_completion_matches('fo', {
        { label = '?.foo', filterText = 'foo' },
        { label = 'faz other', filterText = 'faz other' },
        { label = 'bar', filterText = 'bar' },
      }, {
        { abbr = 'faz other', word = 'faz other' },
        { abbr = '?.foo', word = '?.foo' },
      })
    end)

    it('keeps a prefix match that fuzzy matching tells apart by case', function()
      assert_completion_matches('A', { { label = 'abc' } }, { { abbr = 'abc', word = 'abc' } })
    end)

    it('fuzzy matches on label when filterText is missing or empty', function()
      assert_completion_matches('fo', {
        { label = 'foo', filterText = '' },
        { label = 'faz other' },
        { label = 'bar' },
      }, {
        { abbr = 'faz other', word = 'faz other' },
        { abbr = 'foo', word = 'foo' },
      })
    end)
  end)

  describe('when smartcase is enabled', function()
    before_each(function()
      exec_lua(function()
        vim.opt.smartcase = true
      end)
    end)
    after_each(function()
      exec_lua(function()
        vim.opt.smartcase = false
      end)
    end)

    it('matches filterText case sensitively', function()
      assert_completion_matches('Fo', {
        { label = 'foo', filterText = 'foo' },
        { label = '?.Foo', filterText = 'Foo' },
        { label = 'Faz other', filterText = 'Faz other' },
        { label = 'faz other', filterText = 'faz other' },
        { label = 'bar', filterText = 'bar' },
      }, {
        { abbr = '?.Foo', word = '?.Foo' },
      })
    end)

    it('matches label case sensitively when filterText is missing', function()
      assert_completion_matches('Fo', {
        { label = 'foo' },
        { label = 'Foo' },
        { label = 'Faz other' },
        { label = 'faz other' },
        { label = 'bar' },
      }, {
        { abbr = 'Foo', word = 'Foo' },
      })
    end)

    describe('when ignorecase is enabled', function()
      before_each(function()
        exec_lua(function()
          vim.opt.ignorecase = true
        end)
      end)
      after_each(function()
        exec_lua(function()
          vim.opt.ignorecase = false
        end)
      end)

      it('matches filterText case insensitively if prefix is lowercase', function()
        assert_completion_matches('fo', {
          { label = '?.foo', filterText = 'foo' },
          { label = '?.Foo', filterText = 'Foo' },
          { label = 'Faz other', filterText = 'Faz other' },
          { label = 'faz other', filterText = 'faz other' },
          { label = 'bar', filterText = 'bar' },
        }, {
          { abbr = '?.Foo', word = '?.Foo' },
          { abbr = '?.foo', word = '?.foo' },
        })
      end)

      it(
        'matches label case insensitively if prefix is lowercase and filterText is missing',
        function()
          assert_completion_matches('fo', {
            { label = 'foo' },
            { label = 'Foo' },
            { label = 'Faz other' },
            { label = 'faz other' },
            { label = 'bar' },
          }, {
            { abbr = 'Foo', word = 'Foo' },
            { abbr = 'foo', word = 'foo' },
          })
        end
      )

      it('matches filterText case sensitively if prefix has uppercase letters', function()
        assert_completion_matches('Fo', {
          { label = 'foo', filterText = 'foo' },
          { label = '?.Foo', filterText = 'Foo' },
          { label = 'Faz other', filterText = 'Faz other' },
          { label = 'faz other', filterText = 'faz other' },
          { label = 'bar', filterText = 'bar' },
        }, {
          { abbr = '?.Foo', word = '?.Foo' },
        })
      end)

      it(
        'matches label case sensitively if prefix has uppercase letters and filterText is missing',
        function()
          assert_completion_matches('Fo', {
            { label = 'foo' },
            { label = 'Foo' },
            { label = 'Faz other' },
            { label = 'faz other' },
            { label = 'bar' },
          }, {
            { abbr = 'Foo', word = 'Foo' },
          })
        end
      )
    end)
  end)

  describe('when ignorecase is enabled', function()
    before_each(function()
      exec_lua(function()
        vim.opt.ignorecase = true
      end)
    end)
    after_each(function()
      exec_lua(function()
        vim.opt.ignorecase = false
      end)
    end)

    it('matches filterText case insensitively', function()
      assert_completion_matches('Fo', {
        { label = '?.foo', filterText = 'foo' },
        { label = '?.Foo', filterText = 'Foo' },
        { label = 'Faz other', filterText = 'Faz other' },
        { label = 'faz other', filterText = 'faz other' },
        { label = 'bar', filterText = 'bar' },
      }, {
        { abbr = '?.Foo', word = '?.Foo' },
        { abbr = '?.foo', word = '?.foo' },
      })
    end)

    it('matches label case insensitively when filterText is missing', function()
      assert_completion_matches('Fo', {
        { label = 'foo' },
        { label = 'Foo' },
        { label = 'Faz other' },
        { label = 'faz other' },
        { label = 'bar' },
      }, {
        { abbr = 'Foo', word = 'Foo' },
        { abbr = 'foo', word = 'foo' },
      })
    end)
  end)

  it('works on non word prefix', function()
    local completion_list = {
      { label = ' foo', insertText = '->foo', sortText = '1' },
      { label = ' bar', insertText = '->bar', filterText = 'bar', sortText = '2' },
    }
    local result = complete('wp.|', completion_list, 0)
    eq_partial({
      { abbr = ' foo', word = '->foo' },
      { abbr = ' bar', word = '->bar' },
    }, result.items)

    local item = {
      filterText = '.ab c',
      label = 'ab c',
      textEdit = {
        newText = '["ab c"]',
        range = { start = { line = 0, character = 3 }, ['end'] = { line = 0, character = 6 } },
      },
    }
    eq({ { abbr = 'ab c', word = 'ab c' } }, shown('xyz.ab|', { item }))
  end)

  it('trims trailing newline or tab from textEdit and insertText', function()
    local range0 = {
      start = { line = 0, character = 0 },
      ['end'] = { line = 0, character = 0 },
    }
    local items = {
      {
        detail = 'ansible.builtin',
        filterText = 'lineinfile ansible.builtin.lineinfile builtin ansible',
        kind = 7,
        label = 'ansible.builtin.lineinfile',
        sortText = '2_ansible.builtin.lineinfile',
        textEdit = {
          newText = 'ansible.builtin.lineinfile:\n	',
          range = range0,
        },
      },
      {
        kind = 7,
        label = 'ansible.builtin.copy',
        sortText = '3_ansible.builtin.copy',
        insertText = 'ansible.builtin.copy:\n	',
      },
    }
    eq_partial({
      { abbr = 'ansible.builtin.lineinfile', word = 'ansible.builtin.lineinfile:' },
      { abbr = 'ansible.builtin.copy', word = 'ansible.builtin.copy:' },
    }, complete('|', items).items)
  end)

  it('handles multiword textEdits', function()
    local range0 = {
      start = { line = 0, character = 0 },
      ['end'] = { line = 0, character = 0 },
    }
    local items = {
      {
        detail = 'abc',
        filterText = 'abc',
        kind = 7,
        label = 'abc',
        sortText = 'abc',
        textEdit = {
          newText = 'abc: Abc',
          range = range0,
        },
      },
    }
    eq_partial({ { abbr = 'abc', word = 'abc: Abc' } }, complete('|', items).items)
  end)

  it('prefers wordlike components for snippets', function()
    -- There are two goals here:
    --
    -- 1. The `word` should match what the user started typing, so that vim.fn.complete() doesn't
    --    filter it away, preventing snippet expansion
    --
    -- For example, if they type `items@ins`, luals returns `table.insert(items, $0)` as
    -- textEdit.newText and `insert` as label.
    -- There would be no prefix match if textEdit.newText is used as `word`
    --
    -- 2. If users do not expand a snippet, but continue typing, they should see a somewhat reasonable
    --    `word` getting inserted.
    --
    -- For example in:
    --
    --  insertText: "testSuites ${1:Env}"
    --  label: "testSuites"
    --
    -- "testSuites" should have priority as `word`, as long as the full snippet gets expanded on accept (<c-y>)
    local range0 = {
      start = { line = 0, character = 0 },
      ['end'] = { line = 0, character = 0 },
    }
    local completion_list = {
      -- luals postfix snippet (typed text: items@ins|)
      {
        label = 'insert',
        insertTextFormat = 2,
        textEdit = {
          newText = 'table.insert(items, $0)',
          range = range0,
        },
      },
      -- eclipse.jdt.ls `new` snippet
      {
        label = 'new',
        insertTextFormat = 2,
        textEdit = {
          newText = '${1:Object} ${2:foo} = new ${1}(${3});\n${0}',
          range = range0,
        },
        textEditText = '${1:Object} ${2:foo} = new ${1}(${3});\n${0}',
      },
      -- eclipse.jdt.ls `List.copyO` function call completion
      {
        label = 'copyOf(Collection<? extends E> coll) : List<E>',
        insertTextFormat = 2,
        insertText = 'copyOf',
        textEdit = {
          newText = 'copyOf(${1:coll})',
          range = range0,
        },
      },
      -- luals for snippet
      {
        insertText = 'for ${1:index}, ${2:value} in ipairs(${3:t}) do\n\t$0\nend',
        insertTextFormat = 2,
        kind = 15,
        label = 'for .. ipairs',
      },
    }
    local expected = {
      {
        abbr = 'copyOf(Collection<? extends E> coll) : List<E>',
        filter_text = 'copyOf(Collection<? extends E> coll) : List<E>',
        word = 'copyOf',
      },
      { abbr = 'for .. ipairs', word = 'for .. ipairs' },
      { abbr = 'insert', word = 'insert' },
      { abbr = 'new', word = 'new' },
    }
    eq_partial(expected, complete('|', completion_list).items)
  end)

  it('uses correct start boundary', function()
    local completion_list = {
      isIncomplete = false,
      items = {
        {
          filterText = 'this_thread',
          insertText = 'this_thread',
          insertTextFormat = 1,
          kind = 9,
          label = ' this_thread',
          score = 1.3205767869949,
          sortText = '4056f757this_thread',
          textEdit = {
            newText = 'this_thread',
            range = {
              start = { line = 0, character = 7 },
              ['end'] = { line = 0, character = 11 },
            },
          },
        },
      },
    }
    local expected = {
      completion_match({
        abbr = ' this_thread',
        kind = 'Module',
        word = 'this_thread',
      }),
    }
    local result = complete('  std::this|', completion_list)
    for _, item in ipairs(result.items) do
      item.user_data = nil
    end
    eq(expected, result.items)
  end)

  it('should search from start boundary to cursor position', function()
    local completion_list = {
      isIncomplete = false,
      items = {
        {
          filterText = 'this_thread',
          insertText = 'this_thread',
          insertTextFormat = 1,
          kind = 9,
          label = ' this_thread',
          score = 1.3205767869949,
          sortText = '4056f757this_thread',
          textEdit = {
            newText = 'this_thread',
            range = {
              start = { line = 0, character = 7 },
              ['end'] = { line = 0, character = 11 },
            },
          },
        },
        {
          filterText = 'no_match',
          insertText = 'notthis_thread',
          insertTextFormat = 1,
          kind = 9,
          label = ' notthis_thread',
          score = 1.3205767869949,
          sortText = '4056f757this_thread',
          textEdit = {
            newText = 'notthis_thread',
            range = {
              start = { line = 0, character = 7 },
              ['end'] = { line = 0, character = 11 },
            },
          },
        },
      },
    }
    local expected = completion_match({
      abbr = ' this_thread',
      kind = 'Module',
      word = 'this_thread',
    })
    local result = complete('  std::this|is', completion_list)
    eq(1, #result.items)
    local item = result.items[1]
    item.user_data = nil
    eq(expected, item)
  end)

  it('uses defaults from itemDefaults', function()
    --- @type lsp.CompletionList
    local completion_list = {
      isIncomplete = false,
      itemDefaults = {
        editRange = {
          start = { line = 1, character = 1 },
          ['end'] = { line = 1, character = 4 },
        },
        insertTextFormat = 2,
        data = 'foobar',
      },
      items = {
        {
          label = 'hello',
          data = 'item-property-has-priority',
          textEditText = 'hello',
        },
      },
    }
    local result = complete('|', completion_list)
    eq(1, #result.items)
    local item = result.items[1].user_data.nvim.lsp.completion_item --- @type lsp.CompletionItem
    eq(2, item.insertTextFormat)
    eq('item-property-has-priority', item.data)
    eq({ line = 1, character = 1 }, item.textEdit.range.start)

    local default_range = completion_list.itemDefaults.editRange
    local item_range = vim.deepcopy(default_range)
    item_range.start.character = 0
    for _, edit_range in ipairs({
      default_range,
      { insert = default_range, replace = default_range },
    }) do
      for _, text_edit in ipairs({
        { range = item_range, newText = 'hello' },
        { insert = item_range, replace = item_range, newText = 'hello' },
      }) do
        completion_list.itemDefaults.editRange = edit_range
        completion_list.items[1].textEdit = text_edit
        result = complete('|', completion_list)
        eq(text_edit, result.items[1].user_data.nvim.lsp.completion_item.textEdit)
      end
    end
  end)

  it(
    'uses insertText as textEdit.newText if there are editRange defaults but no textEditText',
    function()
      --- @type lsp.CompletionList
      local completion_list = {
        isIncomplete = false,
        itemDefaults = {
          editRange = {
            start = { line = 1, character = 1 },
            ['end'] = { line = 1, character = 4 },
          },
          insertTextFormat = 2,
          data = 'foobar',
        },
        items = {
          {
            insertText = 'the-insertText',
            label = 'hello',
            data = 'item-property-has-priority',
          },
        },
      }
      local result = complete('|', completion_list)
      eq(1, #result.items)
      eq('the-insertText', result.items[1].user_data.nvim.lsp.completion_item.textEdit.newText)
    end
  )

  it(
    'defaults to label as textEdit.newText if insertText or textEditText are not present',
    function()
      local completion_list = {
        isIncomplete = false,
        itemDefaults = {
          editRange = {
            start = { line = 1, character = 1 },
            ['end'] = { line = 1, character = 4 },
          },
          insertTextFormat = 2,
          data = 'foobar',
        },
        items = {
          {
            label = 'hello',
            data = 'item-property-has-priority',
            insertText = '',
          },
        },
      }
      local result = complete('|', completion_list)
      eq(1, #result.items)
      eq('hello', result.items[1].user_data.nvim.lsp.completion_item.textEdit.newText)
    end
  )

  it('keeps the range of an item over the default editRange', function()
    --- @type lsp.CompletionList
    local completion_list = {
      isIncomplete = false,
      itemDefaults = {
        editRange = {
          insert = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 1 } },
          replace = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 3 } },
        },
      },
      items = {
        {
          label = 'hello',
          textEdit = {
            newText = 'hello',
            range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 1 } },
          },
        },
      },
    }
    local result = complete('h|', completion_list)
    eq(nil, result.items[1].user_data.nvim.lsp.completion_item.textEdit.replace)
  end)

  it('uses the start boundary from an insertReplace response', function()
    local completion_list = {
      isIncomplete = false,
      items = {
        {
          data = { cacheId = 1 },
          kind = 2,
          label = 'foobar',
          sortText = '11',
          textEdit = {
            insert = {
              start = { character = 4, line = 4 },
              ['end'] = { character = 8, line = 4 },
            },
            newText = 'foobar',
            replace = {
              start = { character = 4, line = 4 },
              ['end'] = { character = 8, line = 4 },
            },
          },
        },
        {
          data = { cacheId = 2 },
          kind = 2,
          label = 'bazqux',
          sortText = '11',
          textEdit = {
            insert = {
              start = { character = 4, line = 4 },
              ['end'] = { character = 5, line = 4 },
            },
            newText = 'bazqux',
            replace = {
              start = { character = 4, line = 4 },
              ['end'] = { character = 5, line = 4 },
            },
          },
        },
      },
    }

    local result = complete('foo.f|', completion_list)
    eq(1, #result.items)
    eq('foobar', result.items[1].user_data.nvim.lsp.completion_item.textEdit.newText)
  end)

  --- @param candidates lsp.CompletionList
  --- @return table<string, lsp.CompletionItem>
  local function convert(candidates)
    local items = {} --- @type table<string, lsp.CompletionItem>
    for _, match in ipairs(complete('|', candidates).items) do
      local item = match.user_data.nvim.lsp.completion_item
      items[item.label] = item
    end
    return items
  end

  it('itemDefaults are replaced by the item by default', function()
    local items = convert({
      isIncomplete = false,
      itemDefaults = { commitCharacters = { '.', ';' }, data = { a = 1 } },
      items = {
        { label = 'own', commitCharacters = { '(' }, data = { b = 2 } },
        { label = 'absent' },
        { label = 'empty', commitCharacters = {}, data = false },
      },
    })
    eq({ '(' }, items.own.commitCharacters)
    eq({ b = 2 }, items.own.data)
    eq({ '.', ';' }, items.absent.commitCharacters)
    eq({ a = 1 }, items.absent.data)
    eq({}, items.empty.commitCharacters)
    eq(false, items.empty.data)
  end)

  it('applyKind=Merge merges the item with itemDefaults', function()
    local Merge = 2
    local items = convert({
      isIncomplete = false,
      applyKind = { commitCharacters = Merge, data = Merge },
      itemDefaults = { commitCharacters = { '.', ';' }, data = { a = 1, nested = { x = 1 } } },
      items = {
        { label = 'own', commitCharacters = { '(' }, data = { a = 9, nested = { y = 2 } } },
        { label = 'absent' },
      },
    })
    eq({ '(', '.', ';' }, items.own.commitCharacters)
    eq({ a = 9, nested = { y = 2 } }, items.own.data)
    eq({ '.', ';' }, items.absent.commitCharacters)
    eq({ a = 1, nested = { x = 1 } }, items.absent.data)
  end)
end)

--- @param name string
--- @param completion_result vim.lsp.CompletionResult
--- @param opts? {trigger_chars?: string[], resolve_result?: lsp.CompletionItem|lsp.CompletionItem[], delay?: integer, cmp?: string, insert_mode?: string}
--- @return integer
local function create_server(name, completion_result, opts)
  opts = opts or {}
  return exec_lua(function()
    local server = _G._create_server({
      capabilities = {
        completionProvider = {
          triggerCharacters = opts.trigger_chars or { '.' },
          resolveProvider = opts.resolve_result ~= nil,
        },
      },
      handlers = {
        ['textDocument/completion'] = function(_, _, callback)
          if opts.delay then
            -- simulate delay in completion request, needed for some of these tests
            vim.defer_fn(function()
              callback(nil, completion_result)
            end, opts.delay)
          else
            callback(nil, completion_result)
          end
        end,
        ['completionItem/resolve'] = function(_, request_item, callback)
          if type(opts.resolve_result) == 'table' and not opts.resolve_result.label then
            local selected = vim.fn.complete_info({ 'selected' }).selected
            callback(nil, opts.resolve_result[selected + 1] or request_item)
          else
            callback(nil, opts.resolve_result)
          end
        end,
      },
    })

    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_buf(0, bufnr)
    local cmp_fn
    if opts.cmp then
      cmp_fn = assert(loadstring(opts.cmp))
    end
    return vim.lsp.start({
      name = name,
      cmd = server.cmd,
      on_attach = function(client, bufnr0)
        vim.lsp.completion.enable(true, client.id, bufnr0, {
          autotrigger = opts.trigger_chars ~= nil,
          convert = function(item)
            return { abbr = item.label:gsub('%b()', '') }
          end,
          cmp = cmp_fn,
          insert_mode = opts.insert_mode,
        })
      end,
    })
  end)
end

describe('vim.lsp.completion: protocol', function()
  before_each(function()
    clear()
    exec_lua(create_server_definition)
    exec_lua(function()
      _G.capture = {}
      --- @diagnostic disable-next-line:duplicate-set-field
      vim.api.nvim__complete = function(opts)
        _G.capture.col = opts.col or _G.capture.col
        if opts.items then
          _G.capture.matches = opts.items
        else
          _G.capture.stopped = opts.id -- no items: the session is being ended
        end
        return opts.id or 1
      end
    end)
  end)

  local function assert_matches(fn)
    retry(nil, nil, function()
      fn(exec_lua('return _G.capture.matches'))
    end)
  end

  --- @param pos [integer, integer]
  local function trigger_at_pos(pos)
    exec_lua(function()
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_cursor(win, pos)
      vim.lsp.completion.get()
    end)

    retry(nil, nil, function()
      neq(nil, exec_lua('return _G.capture.col'))
    end)
  end

  --- Collects vim.notify_once into `_G.warnings`. Also keeps a warning from
  --- raising a hit-enter prompt, which would swallow a later feed().
  local function capture_warnings()
    exec_lua(function()
      _G.warnings = {}
      --- @diagnostic disable-next-line:duplicate-set-field
      vim.notify_once = function(msg)
        _G.warnings[#_G.warnings + 1] = msg
        return true
      end
    end)
  end

  --- Starts an autotrigger server ('h' triggers) that answers the Nth request
  --- with the Nth entry of `script`; the last entry repeats. The request count
  --- is in `_G.n_requests`.
  --- @param script { err?: table, result?: table }[]
  local function start_scripted_server(script)
    return exec_lua(function()
      _G.n_requests = 0
      local server = _G._create_server({
        capabilities = { completionProvider = { triggerCharacters = { 'h' } } },
        handlers = {
          ['textDocument/completion'] = function(_, _, callback)
            _G.n_requests = _G.n_requests + 1
            local step = script[math.min(_G.n_requests, #script)]
            callback(step.err, step.result)
          end,
        },
      })
      vim.api.nvim_win_set_buf(0, vim.api.nvim_get_current_buf())
      return vim.lsp.start({
        name = 'scripted',
        cmd = server.cmd,
        on_attach = function(client, bufnr0)
          vim.lsp.completion.enable(true, client.id, bufnr0, { autotrigger = true })
        end,
      })
    end)
  end

  --- Lets any pending debounce timer and re-request run, so that "nothing
  --- more happened" can be asserted.
  local function settle()
    exec_lua(function()
      vim.wait(200, function()
        return false
      end)
    end)
  end

  it('does not error on :checktime after client restart', function()
    local fname = 'Xtest-lsp-completion-reload'
    t.write_file(fname, 'foo')
    t.finally(function()
      os.remove(fname)
    end)
    local mtime = os.time() - 10
    vim.uv.fs_utime(fname, mtime, mtime)
    n.command('edit ' .. fname)
    n.command('set autoread')

    local client_id = create_server('dummy', { isIncomplete = false, items = {} })
    exec_lua(function()
      vim.lsp.get_client_by_id(client_id):stop(true)
      vim.wait(1000, function()
        return vim.lsp.get_client_by_id(client_id) == nil
      end)
    end)
    create_server('dummy', { isIncomplete = false, items = {} })

    t.write_file(fname, 'bar')
    n.command('checktime')
    eq({ 'bar' }, n.api.nvim_buf_get_lines(0, 0, -1, true))
  end)

  it('fetches completions and shows them using complete on trigger', function()
    create_server('dummy', {
      isIncomplete = false,
      items = {
        { label = 'hello' },
        { label = 'hercules', tags = { 1 } }, -- 1 represents Deprecated tag
        { label = 'hero', deprecated = true },
      },
    })

    feed('ih')
    trigger_at_pos({ 1, 1 })

    assert_matches(function(matches)
      eq({
        completion_match({
          abbr = 'hello',
          kind = 'Unknown',
          user_data = {
            nvim = {
              lsp = {
                client_id = 1,
                completion_item = { label = 'hello' },
                info_kind = 'markdown',
                completion_item_needs_resolving = false,
              },
            },
          },
          word = 'hello',
        }),
        completion_match({
          abbr = 'hercules',
          kind = 'Unknown',
          abbr_hlgroup = 'DiagnosticDeprecated',
          user_data = {
            nvim = {
              lsp = {
                client_id = 1,
                completion_item = { label = 'hercules', tags = { 1 } },
                info_kind = 'markdown',
                completion_item_needs_resolving = false,
              },
            },
          },
          word = 'hercules',
        }),
        completion_match({
          abbr = 'hero',
          kind = 'Unknown',
          abbr_hlgroup = 'DiagnosticDeprecated',
          user_data = {
            nvim = {
              lsp = {
                client_id = 1,
                completion_item = { label = 'hero', deprecated = true },
                info_kind = 'markdown',
                completion_item_needs_resolving = false,
              },
            },
          },
          word = 'hero',
        }),
      }, matches)
    end)
  end)

  it('merges results from multiple clients', function()
    create_server('dummy1', { isIncomplete = false, items = { { label = 'hello' } } })
    create_server('dummy2', { isIncomplete = false, items = { { label = 'hallo' } } })
    create_server('dummy3', { { label = 'hallo' } })

    feed('ih')
    trigger_at_pos({ 1, 1 })

    assert_matches(function(matches)
      eq(3, #matches)
      eq('hello', matches[1].word)
      eq('hallo', matches[2].word)
      eq('hallo', matches[3].word)
    end)
  end)

  it('requests only from the given clients', function()
    local id1 = create_server('dummy1', { isIncomplete = false, items = { { label = 'hello' } } })
    local id2 = create_server('dummy2', { isIncomplete = false, items = { { label = 'hallo' } } })
    local id3 = create_server('dummy3', { isIncomplete = false, items = { { label = 'hola' } } })
    feed('ih')

    for _, case in ipairs({ { id2, { 'hallo' } }, { { id1, id3 }, { 'hello', 'hola' } } }) do
      exec_lua(function()
        vim.lsp.completion.get({ client_id = case[1] })
      end)
      assert_matches(function(matches)
        eq(
          case[2],
          vim.tbl_map(function(m)
            return m.word
          end, matches)
        )
      end)
    end
  end)

  it('insert char triggers clients matching trigger characters', function()
    create_server('dummy1', {
      isIncomplete = false,
      items = { { label = 'hello' } },
    }, { trigger_chars = { 'e' } })
    create_server('dummy2', {
      isIncomplete = false,
      items = { { label = 'hallo' } },
    }, { trigger_chars = { 'h' } })

    feed('h')
    exec_lua(function()
      vim.v.char = 'h'
      vim.cmd.startinsert()
      vim.api.nvim_exec_autocmds('InsertCharPre', {})
    end)

    assert_matches(function(matches)
      eq(1, #matches)
      eq('hallo', matches[1].word)
    end)
  end)

  it('reads completionProvider from a dynamic registration', function()
    exec_lua(function()
      local server = _G._create_server({
        capabilities = {},
        handlers = {
          ['textDocument/completion'] = function(_, _, callback)
            callback(nil, { isIncomplete = false, items = { { label = 'hello' } } })
          end,
        },
      })
      local client_id = assert(vim.lsp.start({
        name = 'dummy',
        cmd = server.cmd,
        capabilities = {
          textDocument = { completion = { dynamicRegistration = true } },
        },
      }))
      assert(vim.lsp.get_client_by_id(client_id)):_register({
        {
          id = 'nvim.test.completion',
          method = 'textDocument/completion',
          registerOptions = {
            triggerCharacters = { '.' },
            resolveProvider = true,
            allCommitCharacters = { ';' },
          },
        },
      })
      vim.lsp.completion.enable(true, client_id, 0, { autotrigger = true })
    end)

    feed('i.')

    assert_matches(function(matches)
      eq(1, #matches)
      eq('hello', matches[1].word)
      eq(';', matches[1].commit_chars)
      eq(true, matches[1].user_data.nvim.lsp.completion_item_needs_resolving)
    end)
  end)

  it('treats 2-triggers-at-once as "last char wins"', function()
    create_server('dummy1', {
      isIncomplete = false,
      items = { { label = 'first' } },
    }, { trigger_chars = { '-' } })
    create_server('dummy2', {
      isIncomplete = false,
      items = { { label = 'second' } },
    }, { trigger_chars = { '>' } })

    feed('i->')

    assert_matches(function(matches)
      eq(1, #matches)
      eq('second', matches[1].word)
    end)
  end)

  it('executes commands', function()
    local completion_list = {
      isIncomplete = false,
      items = {
        {
          label = 'hello',
          command = { arguments = { '1', '0' }, command = 'dummy', title = '' },
        },
      },
    }
    local client_id = create_server('dummy', completion_list)

    exec_lua(function()
      _G.called = false
      local client = assert(vim.lsp.get_client_by_id(client_id))
      client.commands.dummy = function()
        _G.called = true
      end
    end)

    feed('ih')
    trigger_at_pos({ 1, 1 })

    local item = completion_list.items[1]
    exec_lua(function()
      vim.v.completed_item = {
        user_data = {
          nvim = {
            lsp = { client_id = client_id, completion_item = item },
          },
        },
      }
    end)

    feed('<C-x><C-o><C-y>')

    assert_matches(function(matches)
      eq(1, #matches)
      eq('hello', matches[1].word)
      eq(true, exec_lua('return _G.called'))
    end)
  end)

  it('resolves and executes commands', function()
    local completion_list = {
      isIncomplete = false,
      items = { { label = 'hello' } },
    }
    local client_id = create_server('dummy', completion_list, {
      resolve_result = {
        label = 'hello',
        command = { arguments = { '1', '0' }, command = 'dummy', title = '' },
      },
    })
    exec_lua(function()
      _G.called = false
      local client = assert(vim.lsp.get_client_by_id(client_id))
      client.commands.dummy = function()
        _G.called = true
      end
    end)

    feed('ih')
    trigger_at_pos({ 1, 1 })

    local item = completion_list.items[1]
    exec_lua(function()
      vim.v.completed_item = {
        user_data = {
          nvim = {
            lsp = { client_id = client_id, completion_item = item },
          },
        },
      }
    end)

    feed('<C-x><C-o><C-y>')

    assert_matches(function(matches)
      eq(1, #matches)
      eq('hello', matches[1].word)
      eq(true, exec_lua('return _G.called'))
    end)
  end)

  it('enable(…,{convert=fn}) custom word/abbr format', function()
    create_server('dummy', {
      isIncomplete = false,
      items = { { label = 'foo(bar)' } },
    })

    feed('ifo')
    trigger_at_pos({ 1, 1 })
    assert_matches(function(matches)
      eq('foo', matches[1].abbr)
    end)
  end)

  it('enable(…,{cmp=fn}) custom sort order', function()
    create_server('dummy', {
      isIncomplete = false,
      items = {
        { label = 'zzz', sortText = 'a' },
        { label = 'aaa', sortText = 'z' },
        { label = 'mmm', sortText = 'm' },
      },
    }, {
      cmp = string.dump(function(a, b)
        return a.abbr < b.abbr
      end),
    })
    feed('i')
    trigger_at_pos({ 1, 0 })
    assert_matches(function(matches)
      eq(3, #matches)
      eq('aaa', matches[1].abbr)
      eq('mmm', matches[2].abbr)
      eq('zzz', matches[3].abbr)
    end)
  end)

  it('sends completion context when invoked', function()
    local params = exec_lua(function()
      local params
      local server = _G._create_server({
        capabilities = { completionProvider = {} },
        handlers = {
          ['textDocument/completion'] = function(_, params0, callback)
            params = params0
            callback(nil, nil)
          end,
        },
      })

      local bufnr = vim.api.nvim_get_current_buf()
      vim.api.nvim_win_set_buf(0, bufnr)
      vim.lsp.start({
        name = 'dummy',
        cmd = server.cmd,
        on_attach = function(client, bufnr0)
          vim.lsp.completion.enable(true, client.id, bufnr0)
        end,
      })

      vim.lsp.completion.get()

      return params
    end)

    eq({ triggerKind = 1 }, params.context)
  end)

  it('sends completion context with trigger characters', function()
    local client_id = exec_lua(function()
      local server = _G._create_server({
        capabilities = {
          completionProvider = { triggerCharacters = { 'h' } },
        },
        handlers = {
          ['textDocument/completion'] = function(_, params, callback)
            _G.params = params
            callback(nil, { isIncomplete = false, items = { label = 'hello' } })
          end,
        },
      })

      local bufnr = vim.api.nvim_get_current_buf()
      vim.api.nvim_win_set_buf(0, bufnr)
      vim.lsp.start({
        name = 'dummy',
        cmd = server.cmd,
        on_attach = function(client, bufnr0)
          vim.lsp.completion.enable(true, client.id, bufnr0, { autotrigger = true })
        end,
      })
    end)

    feed('ih')

    retry(100, nil, function()
      eq({ triggerKind = 2, triggerCharacter = 'h' }, exec_lua('return _G.params.context'))
    end)
  end)

  it('reports items=null without dropping the other clients #39400', function()
    capture_warnings()
    create_server('bad', { isIncomplete = false, items = vim.NIL })
    create_server('good', { isIncomplete = false, items = { { label = 'hello' } } })

    feed('ih')
    trigger_at_pos({ 1, 1 })

    assert_matches(function(matches)
      eq(1, #matches)
      eq('hello', matches[1].word)
    end)
    t.matches('items=null', exec_lua('return table.concat(_G.warnings, " ")'))
  end)

  it('keeps requerying while the completion list is incomplete #40096', function()
    exec_lua(function()
      _G.contexts = {}
      local server = _G._create_server({
        capabilities = {
          completionProvider = { triggerCharacters = { 'h' } },
        },
        handlers = {
          ['textDocument/completion'] = function(_, params, callback)
            _G.contexts[#_G.contexts + 1] = params.context
            callback(nil, { isIncomplete = true, items = { { label = 'hello' } } })
          end,
        },
      })
      local bufnr = vim.api.nvim_get_current_buf()
      vim.api.nvim_win_set_buf(0, bufnr)
      vim.lsp.start({
        name = 'dummy',
        cmd = server.cmd,
        on_attach = function(client, bufnr0)
          vim.lsp.completion.enable(true, client.id, bufnr0, { autotrigger = true })
        end,
      })
    end)
    feed('ih')
    assert_matches(function(matches)
      eq('hello', matches[1].word)
    end)
    eq({ triggerKind = 2, triggerCharacter = 'h' }, exec_lua('return _G.contexts[1]'))

    exec_lua('_G.capture = {}')
    feed('e')
    assert_matches(function(matches)
      eq('hello', matches[1].word)
    end)
    eq({ triggerKind = 3 }, exec_lua('return _G.contexts[2]'))
  end)

  it('asks a client first asked while following up an incomplete list as invoked', function()
    exec_lua(function()
      _G.contexts = { a = {}, b = {} }
      for name, opts in pairs({
        a = { triggerCharacters = { 'h' }, incomplete = true, label = 'hello' },
        b = { label = 'help' },
      }) do
        local server = _G._create_server({
          capabilities = {
            completionProvider = { triggerCharacters = opts.triggerCharacters },
          },
          handlers = {
            ['textDocument/completion'] = function(_, params, callback)
              table.insert(_G.contexts[name], params.context)
              callback(nil, { isIncomplete = opts.incomplete, items = { { label = opts.label } } })
            end,
          },
        })
        vim.lsp.start({
          name = name,
          cmd = server.cmd,
          on_attach = function(client, bufnr)
            vim.lsp.completion.enable(true, client.id, bufnr, {
              autotrigger = true,
              identifier = name == 'b',
            })
          end,
        })
      end
    end)
    feed('ih')
    retry(nil, nil, function()
      eq(1, #exec_lua('return _G.contexts.a'))
    end)
    feed('e')
    retry(nil, nil, function()
      eq({ triggerKind = 3 }, exec_lua('return _G.contexts.a[2]'))
      eq({ { triggerKind = 1 } }, exec_lua('return _G.contexts.b'))
    end)
  end)

  for _, case in ipairs({
    { 'a null result', {} },
    { 'an error response', { err = { code = -32603, message = 'boom' } } },
  }) do
    it('drops the list and the incomplete flag on ' .. case[1], function()
      capture_warnings()
      start_scripted_server({
        { result = { isIncomplete = true, items = { { label = 'hello' } } } },
        case[2],
      })

      feed('ih')
      assert_matches(function(matches)
        eq('hello', matches[1].word)
      end)

      exec_lua('_G.capture = {}')
      feed('e')
      retry(nil, nil, function()
        eq(2, exec_lua('return _G.n_requests'))
      end)
      retry(nil, nil, function()
        eq(1, exec_lua('return _G.capture.stopped'))
      end)

      feed('l')
      settle()
      eq(2, exec_lua('return _G.n_requests'))
    end)
  end

  it('keeps the cached list when the server answers ContentModified', function()
    capture_warnings()
    start_scripted_server({
      { result = { isIncomplete = true, items = { { label = 'hello' } } } },
      { err = { code = -32801, message = 'content modified' } },
    })

    feed('ih')
    assert_matches(function(matches)
      eq('hello', matches[1].word)
    end)

    feed('e')
    retry(nil, nil, function()
      eq(2, exec_lua('return _G.n_requests'))
    end)

    settle()
    assert_matches(function(matches)
      eq('hello', matches[1].word)
    end)
    eq({}, exec_lua('return _G.warnings'))

    feed('l')
    retry(nil, nil, function()
      eq(3, exec_lua('return _G.n_requests'))
    end)
  end)

  it('publishes the other clients when one request is not dispatched', function()
    capture_warnings()
    local id1 = create_server('dummy1', { isIncomplete = false, items = { { label = 'hello' } } })
    create_server('dummy2', { isIncomplete = false, items = { { label = 'hallo' } } })

    exec_lua(function()
      local client = assert(vim.lsp.get_client_by_id(id1))
      --- @diagnostic disable-next-line:duplicate-set-field
      client.request = function()
        return false -- server restarting, buffer detached, ...
      end
    end)

    feed('ih')
    trigger_at_pos({ 1, 1 })

    assert_matches(function(matches)
      eq(1, #matches)
      eq('hallo', matches[1].word)
    end)
  end)

  it('drops a disabled client from an in-progress session', function()
    local id1 = create_server(
      'dummy1',
      { isIncomplete = true, items = { { label = 'hello' } } },
      { trigger_chars = { 'h' } }
    )
    create_server(
      'dummy2',
      { isIncomplete = true, items = { { label = 'help' } } },
      { trigger_chars = { 'h' } }
    )

    feed('ih')
    assert_matches(function(matches)
      eq(2, #matches)
    end)

    exec_lua(function()
      vim.lsp.completion.enable(false, id1, vim.api.nvim_get_current_buf())
    end)

    exec_lua('_G.capture = {}')
    feed('e') -- dummy2 is still incomplete, so this re-queries and republishes
    assert_matches(function(matches)
      eq(1, #matches)
      eq('help', matches[1].word)
    end)
  end)

  it('honours clearing completionProvider on the client', function()
    local id1 = create_server('dummy1', { isIncomplete = false, items = { { label = 'hello' } } })
    create_server('dummy2', { isIncomplete = false, items = { { label = 'hallo' } } })

    exec_lua(function()
      assert(vim.lsp.get_client_by_id(id1)).server_capabilities.completionProvider = nil
    end)

    feed('ih')
    trigger_at_pos({ 1, 1 })

    assert_matches(function(matches)
      eq(1, #matches)
      eq('hallo', matches[1].word)
    end)
  end)
end)

describe('vim.lsp.completion: integration', function()
  before_each(function()
    clear()
    exec_lua(create_server_definition)
  end)

  it('puts cursor at the end of completed word', function()
    local completion_list = {
      isIncomplete = false,
      items = {
        {
          label = 'hello',
          insertText = '${1:hello} friends',
          insertTextFormat = 2,
        },
      },
    }
    exec_lua(function()
      vim.o.completeopt = 'menuone,noselect'
    end)
    local client_id = create_server('dummy', completion_list)
    feed('i world<esc>0ih<c-x><c-o>')
    wait_for_pum()
    feed('<C-n><C-y>')
    eq(
      { true, { 'hello friends world' } },
      exec_lua(function()
        return {
          vim.snippet.active({ direction = 1 }),
          vim.api.nvim_buf_get_lines(0, 0, -1, true),
        }
      end)
    )
    exec_lua(function()
      vim.snippet.jump(1)
    end)
    eq(
      #'hello friends',
      exec_lua(function()
        return vim.api.nvim_win_get_cursor(0)[2]
      end)
    )
    assert_cleanup_after_detach(client_id)
  end)

  --- @param new_text string text the edit inserts at (0,0)
  --- @param expected string[] resulting buffer
  local function snippet_after_edit(new_text, expected)
    exec_lua(function()
      vim.o.completeopt = 'menuone,noselect'
    end)
    create_server('dummy', {
      isIncomplete = false,
      items = {
        {
          label = 'hello',
          insertText = 'hello(${1:arg})',
          insertTextFormat = 2,
          additionalTextEdits = {
            {
              range = {
                start = { line = 0, character = 0 },
                ['end'] = { line = 0, character = 0 },
              },
              newText = new_text,
            },
          },
        },
      },
    })
    feed('ih<c-x><c-o>')
    wait_for_pum()
    feed('<C-n><C-y>')
    eq(
      expected,
      exec_lua(function()
        return vim.api.nvim_buf_get_lines(0, 0, -1, true)
      end)
    )
  end

  it('expands a snippet below an added line', function()
    snippet_after_edit('import x\n', { 'import x', 'hello(arg)' })
  end)

  it('expands a snippet after text added in front of it on the same line', function()
    snippet_after_edit('X', { 'Xhello(arg)' })
  end)

  it('expands a snippet before a slow resolve answers', function()
    exec_lua(function()
      vim.o.completeopt = 'menuone,noselect'
      local server = _G._create_server({
        capabilities = { completionProvider = { resolveProvider = true } },
        handlers = {
          ['textDocument/completion'] = function(_, _, callback)
            callback(nil, {
              isIncomplete = false,
              items = { { label = 'hello', insertText = 'hello($0)', insertTextFormat = 2 } },
            })
          end,
          ['completionItem/resolve'] = function(_, item, callback)
            vim.defer_fn(function()
              callback(nil, item)
            end, 100)
          end,
        },
      })
      local client_id = assert(vim.lsp.start({ name = 'dummy', cmd = server.cmd }))
      vim.lsp.completion.enable(true, client_id, 0)
    end)
    feed('S<C-x><C-o>')
    wait_for_pum()
    feed('<C-n><C-y>x')
    eq({ 'hello(x)' }, n.api.nvim_buf_get_lines(0, 0, -1, true))
  end)

  it('expands the snippet even when the buffer moves during resolve', function()
    exec_lua(function()
      vim.o.completeopt = 'menuone,noselect'
      local server = _G._create_server({
        capabilities = { completionProvider = { resolveProvider = true } },
        handlers = {
          ['textDocument/completion'] = function(_, _, callback)
            callback(nil, {
              isIncomplete = false,
              items = {
                { label = 'hello', insertText = 'hello(${1:arg})', insertTextFormat = 2 },
              },
            })
          end,
          ['completionItem/resolve'] = function(_, item, callback)
            vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'moved' })
            callback(nil, item)
          end,
        },
      })
      vim.api.nvim_win_set_buf(0, vim.api.nvim_get_current_buf())
      vim.lsp.start({
        name = 'dummy',
        cmd = server.cmd,
        on_attach = function(client, bufnr0)
          vim.lsp.completion.enable(true, client.id, bufnr0)
        end,
      })
    end)

    feed('ih<c-x><c-o>')
    wait_for_pum()
    feed('<C-n><C-y>')

    retry(nil, nil, function()
      eq(
        { 'hello(arg)', 'moved' },
        exec_lua(function()
          return vim.api.nvim_buf_get_lines(0, 0, -1, true)
        end)
      )
    end)
  end)

  it('clear multiple-lines word', function()
    local completion_list = {
      isIncomplete = false,
      items = {
        {
          label = 'then...end',
          sortText = '0001',
          insertText = 'then\n\t$0\nend',
          kind = 15,
          insertTextFormat = 2,
        },
      },
    }
    exec_lua(function()
      vim.o.completeopt = 'menuone,noselect'
    end)
    local client_id = create_server('dummy', completion_list)
    feed('Sif true <C-X><C-O>')
    wait_for_pum()
    feed('<C-n><C-y>')
    eq(
      { false, { 'if true then', '\t', 'end' } },
      exec_lua(function()
        return {
          vim.snippet.active({ direction = 1 }),
          vim.api.nvim_buf_get_lines(0, 0, -1, true),
        }
      end)
    )
    assert_cleanup_after_detach(client_id)
  end)

  it('prepends prefix for items with different start positions', function()
    local completion_list = {
      isIncomplete = false,
      items = {
        {
          label = 'div.foo',
          insertTextFormat = 2,
          textEdit = {
            newText = '<div class="foo">$0</div>',
            range = { start = { line = 0, character = 0 }, ['end'] = { line = 0, character = 7 } },
          },
        },
        {
          label = 'foobar',
          insertTextFormat = 1,
        },
      },
    }
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
    end)
    local client_id = create_server('dummy', completion_list)
    feed('Adiv.foo<C-x><C-O>')
    wait_for_pum()
    feed('<C-Y>')
    eq('<div class="foo"></div>', n.api.nvim_get_current_line())
    eq({ 1, 17 }, n.api.nvim_win_get_cursor(0))

    feed('<Esc>ccdiv.foo<C-x><C-O>')
    wait_for_pum()
    feed('<C-N><C-Y>')
    eq('div.foobar', n.api.nvim_get_current_line())

    assert_cleanup_after_detach(client_id)
  end)

  it('does not empty server start boundary', function()
    local completion_list = {
      isIncomplete = false,
      items = {
        {
          label = 'div.foo',
          insertTextFormat = 2,
          textEdit = {
            newText = '<div class="foo">$0</div>',
            range = {
              start = { line = 0, character = 0 },
              ['end'] = { line = 0, character = 7 },
            },
          },
        },
      },
    }
    local completion_list2 = {
      isIncomplete = false,
      items = { { insertTextFormat = 1, label = 'foo' } },
    }
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
    end)
    create_server('dummy', completion_list)
    create_server('dummy2', completion_list2)
    create_server('dummy3', { isIncomplete = false, items = {} })
    feed('Adiv.foo<C-x><C-O>')
    wait_for_pum()
    feed('<C-Y>')
    eq('<div class="foo"></div>', n.api.nvim_get_current_line())
    eq({ 1, 17 }, n.api.nvim_win_get_cursor(0))
  end)

  it('answers <BS> from the list the engine holds', function()
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
      _G.published = 0
      local complete = vim.api.nvim__complete
      --- @diagnostic disable-next-line:duplicate-set-field
      vim.api.nvim__complete = function(opts)
        if opts.items then
          _G.published = _G.published + 1
        end
        return complete(opts)
      end
      local server = _G._create_server({
        capabilities = { completionProvider = {} },
        handlers = {
          ['textDocument/completion'] = function(_, _, callback)
            callback(nil, {
              isIncomplete = false,
              items = {
                { label = 'hello' },
                { label = 'help' },
                { label = 'hero' },
                { label = 'hand' },
              },
            })
          end,
        },
      })
      vim.lsp.start({
        name = 'dummy',
        cmd = server.cmd,
        on_attach = function(client, bufnr)
          vim.lsp.completion.enable(true, client.id, bufnr)
        end,
      })
    end)
    local function matches()
      return exec_lua(function()
        return vim.tbl_map(function(m)
          return m.word
        end, vim.fn.complete_info({ 'matches' }).matches)
      end)
    end
    feed('ihe')
    exec_lua(function()
      vim.lsp.completion.get()
    end)
    retry(nil, nil, function()
      eq({ 'hello', 'help', 'hero' }, matches())
    end)
    feed('l')
    retry(nil, nil, function()
      eq({ 'hello', 'help' }, matches())
    end)
    feed('<BS>')
    retry(nil, nil, function()
      eq({ 'hello', 'help', 'hero' }, matches())
    end)
    feed('<BS>')
    retry(nil, nil, function()
      eq({ 'hand', 'hello', 'help', 'hero' }, matches())
    end)
    eq(1, exec_lua('return _G.published'))
  end)

  --- Starts a server answering with "labels", filtered by the word before the
  --- cursor when "incomplete", and counts the requests in _G.requests.
  local function start_counting(labels, incomplete)
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
      _G.requests = 0
      local server = _G._create_server({
        capabilities = { completionProvider = {} },
        handlers = {
          ['textDocument/completion'] = function(_, params, callback)
            _G.requests = _G.requests + 1
            local word = vim.api.nvim_get_current_line():sub(1, params.position.character)
            local items = {}
            for _, label in ipairs(labels) do
              if not incomplete or vim.startswith(label, word) then
                items[#items + 1] = { label = label }
              end
            end
            callback(nil, { isIncomplete = incomplete, items = items })
          end,
        },
      })
      vim.lsp.start({
        name = 'dummy',
        cmd = server.cmd,
        on_attach = function(client, bufnr)
          vim.lsp.completion.enable(
            true,
            client.id,
            bufnr,
            { autotrigger = true, identifier = true }
          )
        end,
      })
    end)
  end

  local function shown()
    return exec_lua(function()
      return vim.tbl_map(function(m)
        return m.word
      end, vim.fn.complete_info({ 'matches' }).matches)
    end)
  end

  it('keeps what a later enable() leaves out', function()
    local client_id = create_server('dummy', {
      isIncomplete = false,
      items = { { label = 'hello' }, { label = 'help' } },
    }, { trigger_chars = { '.' } })
    exec_lua(function()
      vim.lsp.completion.enable(true, client_id, 0, { _rank = 1 })
    end)
    feed('i.')
    retry(nil, nil, function()
      eq(1, n.fn.pumvisible())
    end)
  end)

  it('shows the list again on <BS> out of a word nothing matched', function()
    start_counting({ 'hello', 'help' }, false)
    feed('ihe')
    retry(nil, nil, function()
      eq({ 'hello', 'help' }, shown())
    end)
    feed('xx')
    retry(nil, nil, function()
      eq(0, n.fn.pumvisible())
    end)
    feed('<BS><BS>')
    retry(nil, nil, function()
      eq({ 'hello', 'help' }, shown())
    end)
    eq(1, exec_lua('return _G.requests'))
  end)

  it('asks again on <BS> out of a word an incomplete list had nothing for', function()
    start_counting({ 'hello', 'help' }, true)
    feed('ihe')
    retry(nil, nil, function()
      eq({ 'hello', 'help' }, shown())
    end)
    feed('x')
    retry(nil, nil, function()
      eq(0, n.fn.pumvisible())
    end)
    local asked = exec_lua('return _G.requests')
    feed('<BS>')
    retry(nil, nil, function()
      eq({ 'hello', 'help' }, shown())
      eq(true, exec_lua('return _G.requests') > asked)
    end)
  end)

  it('requeries an incomplete list on <BS>', function()
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
      _G.count = 0
      local server = _G._create_server({
        capabilities = { completionProvider = { triggerCharacters = { 'h' } } },
        handlers = {
          ['textDocument/completion'] = function(_, _, callback)
            _G.count = _G.count + 1
            callback(nil, { isIncomplete = true, items = { { label = 'hello' } } })
          end,
        },
      })
      vim.lsp.start({
        name = 'dummy',
        cmd = server.cmd,
        on_attach = function(client, bufnr)
          vim.lsp.completion.enable(true, client.id, bufnr, { autotrigger = true })
        end,
      })
    end)
    local function wait(count)
      retry(nil, nil, function()
        eq(count, exec_lua('return _G.count'))
      end)
    end
    feed('ih')
    wait(1)
    feed('e')
    wait(2)
    feed('<BS>')
    wait(3)
  end)

  it('stops re-querying an incomplete list after leaving the completion', function()
    local completion_list = {
      isIncomplete = true,
      items = { { label = 'wp_handle' } },
    }
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
    end)
    local client_id = create_server('dummy', completion_list, { trigger_chars = { '>' } })

    feed('iwp-><C-x><C-o>')
    wait_for_pum()
    feed('<BS><BS>')
    n.poke_eventloop()
    -- not a trigger character
    feed('-')
    n.poke_eventloop()
    eq(0, n.fn.pumvisible())
    assert_cleanup_after_detach(client_id)
  end)

  it('anchors an item without a text edit at overlapping text #30905', function()
    local completion_list = {
      isIncomplete = false,
      items = {
        {
          label = '/**',
          insertTextFormat = 2,
          insertText = '/** ${1:hello} */',
        },
      },
    }
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
    end)
    local client_id = create_server('dummy', completion_list)
    feed('A/<C-x><C-O>')
    wait_for_pum()
    feed('<C-Y>')
    eq('/** hello */', n.api.nvim_get_current_line())
    assert_cleanup_after_detach(client_id)
  end)

  describe('a match that replaces text in front of the word', function()
    -- clangd's dot-to-arrow: the edit replaces the `.`, filterText is the member.
    local completion_list = {
      isIncomplete = false,
      items = {
        {
          filterText = 'member',
          insertTextFormat = 1,
          kind = 5,
          label = ' member',
          textEdit = {
            newText = '->member',
            range = {
              start = { character = 1, line = 0 },
              ['end'] = { character = 2, line = 0 },
            },
          },
        },
      },
    }

    it('shows the text it is filtered by while selected, and applies on accept', function()
      exec_lua(function()
        vim.o.completeopt = 'menu,menuone'
      end)
      local client_id = create_server('dummy', completion_list)
      feed('ip.<C-x><C-o>')
      wait_for_pum()
      eq('p.member', n.api.nvim_get_current_line())
      feed('<C-y>')
      eq('p->member', n.api.nvim_get_current_line())
      assert_cleanup_after_detach(client_id)
    end)

    it("is previewed, not written, with 'preinsert'", function()
      local client_id = create_server('dummy', completion_list)
      for _, cot in ipairs({ 'menu,menuone,preinsert', 'menu,menuone,preinsert,fuzzy' }) do
        n.command('set completeopt=' .. cot)
        n.api.nvim_buf_set_lines(0, 0, -1, true, { '' })
        feed('ip.<C-x><C-o>')
        wait_for_pum()
        eq('p.', n.api.nvim_get_current_line())
        eq('member', preview_text())
        feed('<C-y>')
        eq('p->member', n.api.nvim_get_current_line())
        eq(nil, preview_text())
        feed('<Esc>')
      end
      assert_cleanup_after_detach(client_id)
    end)

    it("is previewed under 'autocomplete' without 'menuone'", function()
      exec_lua(function()
        vim.o.completeopt = 'menu,preinsert'
        vim.o.autocomplete = true
      end)
      local client_id = create_server('dummy', {
        isIncomplete = false,
        items = {
          {
            filterText = 'member',
            label = ' member',
            textEdit = {
              newText = '->member',
              range = {
                start = { character = 1, line = 0 },
                ['end'] = { character = 2, line = 0 },
              },
            },
          },
          {
            filterText = 'method',
            label = ' method',
            textEdit = {
              newText = '->method',
              range = {
                start = { character = 1, line = 0 },
                ['end'] = { character = 2, line = 0 },
              },
            },
          },
        },
      })
      feed('ip.<C-x><C-o>')
      wait_for_pum()
      eq('p.', n.api.nvim_get_current_line())
      eq('member', preview_text())
      exec_lua(function()
        vim.o.autocomplete = false
      end)
      assert_cleanup_after_detach(client_id)
    end)

    it("is not applied when the 'preinsert' preview is dropped", function()
      exec_lua(function()
        vim.o.completeopt = 'menu,menuone,preinsert'
      end)
      local client_id = create_server('dummy', completion_list)
      feed('ip.<C-x><C-o>')
      wait_for_pum()
      eq('member', preview_text())
      feed('<Esc>')
      eq('p.', n.api.nvim_get_current_line())
      eq(nil, preview_text())
      assert_cleanup_after_detach(client_id)
    end)

    it('is applied only when accepted', function()
      exec_lua(function()
        vim.o.completeopt = 'menu,menuone'
        vim.api.nvim_create_autocmd('CompleteDone', {
          callback = function()
            _G.reason = vim.v.event.reason
          end,
        })
      end)
      local client_id = create_server('dummy', completion_list)
      feed('ip.<C-x><C-o>')
      wait_for_pum()
      feed('<Esc>')
      eq({ 'p.member', 'discard' }, { n.api.nvim_get_current_line(), exec_lua('return _G.reason') })
      feed('Sp.<C-x><C-o>')
      wait_for_pum()
      feed('(')
      eq('p.member(', n.api.nvim_get_current_line())
      assert_cleanup_after_detach(client_id)
    end)

    it('is applied on accept', function()
      local client_id = create_server('dummy', completion_list)
      for _, cot in ipairs({ 'menu,menuone', 'menu,menuone,preinsert' }) do
        n.command('set completeopt=' .. cot)
        feed('<Esc>Sp.<C-x><C-o>')
        wait_for_pum()
        feed('<C-y>')
        eq('p->member', n.api.nvim_get_current_line())
        eq({ 1, 9 }, n.api.nvim_win_get_cursor(0))
      end
      assert_cleanup_after_detach(client_id)
    end)

    it('is not left half-applied by a backspace', function()
      exec_lua(function()
        vim.o.completeopt = 'menu,menuone'
      end)
      local client_id = create_server('dummy', completion_list)
      feed('ip.mem<C-x><C-o>')
      wait_for_pum()
      eq('p.member', n.api.nvim_get_current_line())
      feed('<BS>')
      eq('p.me', n.api.nvim_get_current_line())
      assert_cleanup_after_detach(client_id)
    end)

    it('keeps the preview when an incomplete list is refreshed', function()
      exec_lua(function()
        vim.o.completeopt = 'menu,menuone,preinsert'
      end)
      local incomplete = vim.deepcopy(completion_list)
      incomplete.isIncomplete = true
      local client_id = create_server('dummy', incomplete)
      feed('ip.<C-x><C-o>')
      wait_for_pum()
      eq('member', preview_text())
      feed('m')
      retry(nil, nil, function()
        eq('ember', preview_text())
      end)
      eq('p.m', n.api.nvim_get_current_line())
      assert_cleanup_after_detach(client_id)
    end)

    it("backspaces the typed text, not the preview, with 'preinsert'", function()
      exec_lua(function()
        vim.o.completeopt = 'menu,menuone,preinsert'
      end)
      local client_id = create_server('dummy', completion_list)
      feed('ip.<C-x><C-o>')
      wait_for_pum()
      feed('m')
      wait_for_pum()
      feed('<BS>')
      eq('p.', n.api.nvim_get_current_line())
      assert_cleanup_after_detach(client_id)
    end)

    it('adds from the filter text, not the edit text, on CTRL-L', function()
      exec_lua(function()
        vim.o.completeopt = 'menu,menuone,preinsert'
      end)
      local client_id = create_server('dummy', completion_list)
      feed('ip.<C-x><C-o>')
      wait_for_pum()
      feed('<C-l>')
      eq('p.m', n.api.nvim_get_current_line())
      eq('ember', preview_text())
      assert_cleanup_after_detach(client_id)
    end)

    it('is undone by CTRL-E', function()
      exec_lua(function()
        vim.o.completeopt = 'menu,menuone'
      end)
      local client_id = create_server('dummy', completion_list)
      feed('ip.<C-x><C-o>')
      wait_for_pum()
      eq('p.member', n.api.nvim_get_current_line())
      feed('<C-e>')
      eq('p.', n.api.nvim_get_current_line())
      assert_cleanup_after_detach(client_id)
    end)
  end)

  it('applies an edit that replaces text in front of the word', function()
    -- clangd's dot-to-arrow: the edit replaces the `.`, filterText is the member.
    local function member(name, text)
      return {
        detail = 'int',
        filterText = name,
        insertTextFormat = 1,
        kind = 5,
        label = ' ' .. name,
        sortText = '4122d903' .. name,
        textEdit = {
          newText = text,
          range = {
            start = { character = 2, line = 0 },
            ['end'] = { character = 3, line = 0 },
          },
        },
      }
    end
    local completion_list = {
      isIncomplete = true,
      items = {
        member('handle', '->handle'),
        member('w_alt_fnum', '->w_alt_fnum'),
        {
          detail = 'pointer',
          filterText = 'get',
          insertText = '.get()',
          insertTextFormat = 2,
          kind = 2,
          label = ' get',
          labelDetails = { detail = '() const' },
          sortText = '411198afget',
          textEdit = {
            newText = '.get()',
            range = {
              start = { character = 2, line = 0 },
              ['end'] = { character = 4, line = 0 },
            },
          },
        },
      },
    }
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
    end)
    local client_id = create_server('dummy', completion_list)

    feed('iwp.<c-x><c-o>')
    wait_for_pum()
    feed('w')
    wait_for_pum()
    feed('<C-y>')
    eq('wp->w_alt_fnum', n.api.nvim_get_current_line())
    eq({ 1, 14 }, n.api.nvim_win_get_cursor(0))

    n.command('set completeopt+=longest') --- #39001
    feed('<ESC>Swp-><C-x><C-O>')
    wait_for_pum()
    feed('<C-N><C-y>')
    eq('wp.get()', n.api.nvim_get_current_line())
    assert_cleanup_after_detach(client_id)
  end)

  it('sorts items when fuzzy is enabled and prefix not empty #33610', function()
    local completion_list = {
      isIncomplete = false,
      items = {
        {
          kind = 21,
          label = '-row-end-1',
          sortText = '0327',
          textEdit = {
            newText = '-row-end-1',
            range = {
              ['end'] = { character = 1, line = 0 },
              start = { character = 0, line = 0 },
            },
          },
        },
        {
          kind = 21,
          label = 'w-1/2',
          sortText = '3052',
          textEdit = {
            newText = 'w-1/2',
            range = {
              ['end'] = { character = 1, line = 0 },
              start = { character = 0, line = 0 },
            },
          },
        },
      },
    }
    exec_lua(function()
      vim.o.completeopt = 'menuone,fuzzy'
    end)
    create_server('dummy', completion_list, { trigger_chars = { '-' } })
    feed('Sw-')
    wait_for_pum()
    feed('<C-y>')
    eq('w-1/2', n.api.nvim_get_current_line())
  end)

  it("takes the whole match back under 'ignorecase'", function()
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone'
      vim.o.ignorecase = true
    end)
    local client_id = create_server('dummy', {
      isIncomplete = false,
      items = { { label = 'Hello' }, { label = 'Helper' } },
    })

    feed('ihe<C-x><C-o>')
    wait_for_pum()
    eq('Hello', n.api.nvim_get_current_line())
    feed('l<C-e>')
    eq('hel', n.api.nvim_get_current_line())
    assert_cleanup_after_detach(client_id)
  end)

  it("takes the whole match back under 'fuzzy'", function()
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,fuzzy'
    end)
    local client_id = create_server('dummy', {
      isIncomplete = false,
      items = { { label = 'hello' } },
    })

    feed('ihl<C-x><C-o>')
    wait_for_pum()
    feed('o<C-e>')
    eq('hlo', n.api.nvim_get_current_line())
    assert_cleanup_after_detach(client_id)
  end)

  it('reports "discard" for a native completion it takes over', function()
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'hello help', '' })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      _G.reasons = {}
      vim.api.nvim_create_autocmd('CompleteDone', {
        callback = function()
          table.insert(_G.reasons, vim.v.event.reason)
        end,
      })
    end)
    create_server('dummy', {
      isIncomplete = false,
      items = { { label = 'hello' } },
    })

    feed('ih<C-n>')
    wait_for_pum()
    exec_lua(function()
      vim.lsp.completion.get()
    end)
    retry(nil, nil, function()
      eq({ 'discard' }, exec_lua('return _G.reasons'))
      eq(
        { 'help', 'hello' },
        exec_lua(function()
          return vim.tbl_map(function(m)
            return m.word
          end, vim.fn.complete_info({ 'items' }).items)
        end)
      )
    end)
  end)

  it('leaves the line alone when a new batch drops the inserted match', function()
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone'
      _G.round = 0
    end)
    local client_id = exec_lua(function()
      local server = _G._create_server({
        capabilities = { completionProvider = { triggerCharacters = { '.' } } },
        handlers = {
          ['textDocument/completion'] = function(_, _, callback)
            _G.round = _G.round + 1
            callback(nil, {
              isIncomplete = _G.round == 1,
              items = _G.round == 1 and { { label = 'hello' } } or { { label = 'helper' } },
            })
          end,
        },
      })
      local id = vim.lsp.start({ name = 'dummy', cmd = server.cmd })
      vim.lsp.completion.enable(true, id, 0, { autotrigger = true })
      return id
    end)

    feed('ih<C-x><C-o>')
    wait_for_pum()
    eq('hello', n.api.nvim_get_current_line())
    feed('e')
    retry(nil, nil, function()
      assert(exec_lua('return _G.round') > 1)
    end)
    eq('he', n.api.nvim_get_current_line())
    assert_cleanup_after_detach(client_id)
  end)

  it('leaves out buffer words while a server offers any', function()
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'hello hint', '' })
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
    end)
    local client_id = create_server('dummy', {
      isIncomplete = false,
      items = { { label = 'hello', kind = 3 } },
    })
    exec_lua(function(id)
      local completion = require('vim._core.completion')
      completion.enable(true, 0, {
        sources = { completion.source.keyword, completion.source.lsp({ client_id = id }) },
      })
    end, client_id)

    retry(nil, nil, function()
      eq(
        2,
        exec_lua(function()
          return #vim.lsp.get_clients({ bufnr = 0, method = 'textDocument/completion' })
        end)
      )
    end)

    feed('ih<C-x><C-o>')
    wait_for_pum()
    retry(nil, nil, function()
      local words = vim.tbl_map(function(m)
        return m.word
      end, n.fn.complete_info({ 'matches' }).matches)
      eq({ 'hello' }, words)
    end)
  end)

  it('selects the head of a replacing batch', function()
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
      _G.round = 0
    end)
    local client_id = exec_lua(function()
      local server = _G._create_server({
        capabilities = { completionProvider = {} },
        handlers = {
          ['textDocument/completion'] = function(_, _, callback)
            _G.round = _G.round + 1
            local later = _G.round > 1
            callback(nil, {
              isIncomplete = true,
              items = {
                { label = 'heap', sortText = later and 'b' or 'a' },
                { label = 'heat', sortText = later and 'a' or 'b' },
              },
            })
          end,
        },
      })
      local id = vim.lsp.start({ name = 'dummy', cmd = server.cmd })
      vim.lsp.completion.enable(true, id, 0, { autotrigger = true })
      return id
    end)

    feed('ih<C-x><C-o>')
    wait_for_pum()
    feed('e')
    retry(nil, nil, function()
      eq({ 'heat', 0 }, {
        n.fn.complete_info({ 'matches' }).matches[1].word,
        n.fn.complete_info({ 'selected' }).selected,
      })
    end)
    assert_cleanup_after_detach(client_id)
  end)

  it('walks the same way after a replacing batch', function()
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
      _G.round = 0
    end)
    local client_id = exec_lua(function()
      local server = _G._create_server({
        capabilities = { completionProvider = {} },
        handlers = {
          ['textDocument/completion'] = function(_, _, callback)
            _G.round = _G.round + 1
            callback(nil, {
              isIncomplete = _G.round == 1,
              items = { { label = 'heap' }, { label = 'heat' }, { label = 'head' } },
            })
          end,
        },
      })
      local id = vim.lsp.start({ name = 'dummy', cmd = server.cmd })
      vim.lsp.completion.enable(true, id, 0, { autotrigger = true })
      return id
    end)

    feed('ihe<C-x><C-o>')
    wait_for_pum()
    feed('<C-p>')
    feed('a')
    retry(nil, nil, function()
      assert(exec_lua('return _G.round') > 1)
    end)
    eq(3, #n.fn.complete_info({ 'matches' }).matches)

    local at = n.fn.complete_info({ 'selected' }).selected
    feed('<C-p>')
    local after = n.fn.complete_info({ 'selected' }).selected
    eq(at == 0 and -1 or at - 1, after)
    assert_cleanup_after_detach(client_id)
  end)

  it("ignores a preselect from a replacing batch under 'noselect' and 'longest'", function()
    local client_id = exec_lua(function()
      local server = _G._create_server({
        capabilities = { completionProvider = {} },
        handlers = {
          ['textDocument/completion'] = function(_, _, callback)
            _G.round = _G.round + 1
            callback(nil, {
              isIncomplete = _G.round == 1,
              items = { { label = 'heap' }, { label = 'heat', preselect = true } },
            })
          end,
        },
      })
      local id = vim.lsp.start({ name = 'dummy', cmd = server.cmd })
      vim.lsp.completion.enable(true, id, 0, { autotrigger = true })
      return id
    end)

    for _, flag in ipairs({ 'noselect', 'longest' }) do
      exec_lua(function()
        vim.o.completeopt = 'menu,menuone,' .. flag
        _G.round = 0
      end)
      n.api.nvim_buf_set_lines(0, 0, -1, true, { '' })
      feed('ihe<C-x><C-o>')
      wait_for_pum()
      feed('a')
      retry(nil, nil, function()
        assert(exec_lua('return _G.round') > 1)
      end)
      eq(2, #n.fn.complete_info({ 'matches' }).matches)
      eq(-1, n.fn.complete_info({ 'selected' }).selected)
      feed('<C-e><Esc>')
    end
    assert_cleanup_after_detach(client_id)
  end)

  it('orders by how well an item matches, not by which client sent it', function()
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert,fuzzy'
    end)
    local first = create_server('dummy1', {
      isIncomplete = false,
      items = { { label = 'hxexlxlxo' } },
    })
    local second = create_server('dummy2', {
      isIncomplete = false,
      items = { { label = 'hello' } },
    })
    exec_lua(function(a, b)
      vim.lsp.completion.enable(true, a, 0, { _rank = 1 })
      vim.lsp.completion.enable(true, b, 0, { _rank = 2 })
    end, first, second)

    feed('ihello<C-x><C-o>')
    wait_for_pum()
    retry(nil, nil, function()
      local words = vim.tbl_map(function(m)
        return m.word
      end, n.fn.complete_info({ 'matches' }).matches)
      eq(2, #words)
      eq('hello', words[1])
    end)
  end)

  it('stops asking once a client answers completely', function()
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
      _G.round = 0
    end)
    local client_id = exec_lua(function()
      local server = _G._create_server({
        capabilities = { completionProvider = {} },
        handlers = {
          ['textDocument/completion'] = function(_, _, callback)
            _G.round = _G.round + 1
            callback(nil, { isIncomplete = false, items = { { label = 'hello' } } })
          end,
        },
      })
      local id = vim.lsp.start({ name = 'dummy', cmd = server.cmd })
      vim.lsp.completion.enable(true, id, 0, { identifier = true })
      return id
    end)

    feed('ih')
    retry(nil, nil, function()
      eq(1, exec_lua('return _G.round'))
    end)
    feed('<C-e>e')
    n.poke_eventloop()
    eq(1, exec_lua('return _G.round'))
    assert_cleanup_after_detach(client_id)
  end)

  it('leaves a client the caller enabled itself alone', function()
    create_server('dummy', {
      isIncomplete = false,
      items = { { label = 'hello' } },
    }, { trigger_chars = { '.' } })
    exec_lua(function()
      local completion = require('vim._core.completion')
      completion.enable(true, 0, { sources = { completion.source.keyword } })
      completion.enable(false, 0)
    end)

    feed('ih.')
    retry(nil, nil, function()
      eq('h.hello', n.api.nvim_get_current_line())
    end)
  end)

  it('keeps the same word from two clients that both own it', function()
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
    end)
    local _ = create_server('dummy1', {
      isIncomplete = false,
      items = { { label = 'hello' } },
    })
    local _ = create_server('dummy2', {
      isIncomplete = false,
      items = { { label = 'hello' } },
    })

    feed('ih<C-x><C-o>')
    wait_for_pum()
    retry(nil, nil, function()
      local hellos = vim.tbl_filter(function(m)
        return m.word == 'hello'
      end, n.fn.complete_info({ 'matches' }).matches)
      eq(2, #hellos)
    end)
  end)

  it("orders two servers' items by rank when nothing scores them", function()
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
    end)
    local first = create_server('dummy1', {
      isIncomplete = false,
      items = { { label = 'hzz', sortText = 'zzz' } },
    })
    local second = create_server('dummy2', {
      isIncomplete = false,
      items = { { label = 'haa', sortText = 'aaa' } },
    })
    exec_lua(function(a, b)
      vim.lsp.completion.enable(true, a, 0, { _rank = 1 })
      vim.lsp.completion.enable(true, b, 0, { _rank = 2 })
    end, first, second)

    feed('ih<C-x><C-o>')
    wait_for_pum()
    retry(nil, nil, function()
      local words = vim.tbl_map(function(m)
        return m.word
      end, n.fn.complete_info({ 'matches' }).matches)
      eq({ 'hzz', 'haa' }, words)
    end)
  end)

  it('scores an incomplete list like any other', function()
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert,fuzzy'
    end)
    local incomplete = create_server('dummy1', {
      isIncomplete = true,
      items = { { label = 'hb' } },
    })
    local whole = create_server('dummy2', {
      isIncomplete = false,
      items = { { label = 'hxxxb' } },
    })
    exec_lua(function(a, b)
      vim.lsp.completion.enable(true, a, 0, { _rank = 2 })
      vim.lsp.completion.enable(true, b, 0, { _rank = 1 })
    end, incomplete, whole)

    feed('ihb<C-x><C-o>')
    wait_for_pum()
    retry(nil, nil, function()
      local words = vim.tbl_map(function(m)
        return m.word
      end, n.fn.complete_info({ 'matches' }).matches)
      eq(2, #words)
      eq('hb', words[1])
    end)
  end)

  it('orders a partial round by score all the same', function()
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert,fuzzy'
    end)
    local _ = create_server('dummy1', {
      isIncomplete = false,
      items = { { label = 'hb' }, { label = 'haab' } },
    })
    local _ = create_server('dummy2', {
      isIncomplete = true,
      items = { { label = 'hab' } },
    })

    feed('ihb<C-x><C-o>')
    wait_for_pum()
    retry(nil, nil, function()
      local words = vim.tbl_map(function(m)
        return m.word
      end, n.fn.complete_info({ 'matches' }).matches)
      eq('hb', words[1])
    end)
  end)

  it('stops looking once a shorter leader matched nothing', function()
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
      _G.converted = 0
      local to_items = vim.lsp.completion._lsp_to_complete_items
      vim.lsp.completion._lsp_to_complete_items = function(...)
        _G.converted = _G.converted + 1
        return to_items(...)
      end
    end)
    local client_id = create_server('dummy', {
      isIncomplete = false,
      items = { { label = 'hello' } },
    })
    exec_lua(function(id)
      vim.lsp.completion.enable(true, id, 0, { identifier = true })
    end, client_id)

    feed('ixq')
    retry(nil, nil, function()
      assert(exec_lua('return _G.converted') > 0)
    end)
    local before = exec_lua('return _G.converted')
    feed('rs')
    n.poke_eventloop()
    eq(before, exec_lua('return _G.converted'))
    assert_cleanup_after_detach(client_id)
  end)

  it('looks again when a partial list answers for a longer leader', function()
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
    end)
    local _ = exec_lua(function()
      local server = _G._create_server({
        capabilities = { completionProvider = {} },
        handlers = {
          ['textDocument/completion'] = function(_, params, callback)
            local col = params.position.character
            callback(nil, {
              isIncomplete = col < 3,
              items = col < 3 and {} or { { label = 'xqrs' } },
            })
          end,
        },
      })
      local id = vim.lsp.start({ name = 'dummy', cmd = server.cmd })
      vim.lsp.completion.enable(true, id, 0, { identifier = true })
      return id
    end)

    feed('ixq')
    n.poke_eventloop()
    eq(0, #n.fn.complete_info({ 'matches' }).matches)
    feed('r')
    retry(nil, nil, function()
      local words = vim.tbl_map(function(m)
        return m.word
      end, n.fn.complete_info({ 'matches' }).matches)
      eq({ 'xqrs' }, words)
    end)
  end)

  it('asks again for a shorter leader', function()
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { '', 'foobar fox' })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local completion = require('vim._core.completion')
      completion.enable(true, 0, { sources = { completion.source.keyword } })
    end)
    local function words()
      return vim.tbl_map(function(m)
        return m.word
      end, n.fn.complete_info({ 'matches' }).matches)
    end

    feed('ifoo')
    retry(nil, nil, function()
      eq({ 'foobar' }, words())
    end)
    feed('<BS>')
    retry(nil, nil, function()
      eq({ 'foobar', 'fox' }, words())
    end)
  end)

  it('enable(…,{insert_mode=…}) applies to an InsertReplaceEdit on the line', function()
    local function list(edit)
      edit.newText = 'foobaz'
      return { isIncomplete = false, items = { { label = 'foobaz', textEdit = edit } } }
    end
    local function range(line, character)
      return {
        start = { line = 0, character = 0 },
        ['end'] = { line = line, character = character },
      }
    end
    local insert_replace = list({ insert = range(0, 3), replace = range(0, 6) })
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
    end)
    for i, case in ipairs({
      { insert_replace, nil, 'foobazbar' },
      { insert_replace, 'replace', 'foobaz' },
      { list({ range = range(0, 3) }), 'replace', 'foobazbar' },
      { list({ insert = range(0, 3), replace = range(1, 2) }), 'replace', 'foobazbar' },
    }) do
      n.api.nvim_buf_set_lines(0, 0, -1, true, { '' })
      local client_id = create_server('dummy' .. i, case[1], { insert_mode = case[2] })
      feed('ifoobar<Esc>2hi<C-x><C-o>')
      wait_for_pum()
      feed('<C-y>')
      eq(case[3], n.api.nvim_get_current_line())
      assert_cleanup_after_detach(client_id)
    end
  end)

  it("preinserted() covers 'longest', not the 'preinsert' preview", function()
    local completion_list = {
      isIncomplete = false,
      items = { { label = 'hello' }, { label = 'help' } },
    }
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,preinsert'
    end)
    local client_id = create_server('dummy', completion_list)
    feed('ihe<C-x><C-o>')
    wait_for_pum()
    eq('he', n.api.nvim_get_current_line())
    eq('llo', preview_text())
    eq(0, n.fn.preinserted())
    eq('', n.fn.complete_info({ 'preinserted_text' }).preinserted_text)
    assert_cleanup_after_detach(client_id)
  end)

  describe('selecting an item triggers (snippet) preview', function()
    ---@type lsp.CompletionItem[]
    local incomplete_items = {
      {
        -- detail populated but not documentation
        detail = '(method) nvim__id_array_1(arr: any[]): any[]',
        insertText = 'nvim__id_array_1',
        insertTextFormat = 1,
        kind = 3,
        label = 'nvim__id_array_1(arr)',
        sortText = '0001',
      },
      {
        -- documentation populated but not detail
        documentation = {
          kind = 'markdown',
          value = [[```lua\nfunction vim.api.nvim__id_array_2(arr: any[])\n  -> any[]\n```]],
        },
        insertText = 'nvim__id_array_2',
        insertTextFormat = 1,
        kind = 3,
        label = 'nvim__id_array_2(arr)',
        sortText = '0002',
      },
      {
        insertText = 'for ${1:i} = ${2:1}, ${3:10, 1} do\n\t$0\nend',
        insertTextFormat = 2,
        kind = 15,
        label = 'for i = ..',
        sortText = '0003',
      },
      {
        textEdit = {
          newText = 'for ${1:j} = ${2:1}, ${3:10, 1} do\n\t$0\nend',
          range = {
            start = { character = 0, line = 0 },
            ['end'] = { character = 0, line = 0 },
          },
        },
        insertTextFormat = 2,
        kind = 15,
        label = 'for j = ..',
        sortText = '0004',
      },
      {
        insertText = '_assert_integer(${1:x}, ${2:base?})',
        insertTextFormat = 2,
        kind = 3,
        label = '_assert_integer(x, base)',
        sortText = '0005',
      },
    }
    ---@type lsp.CompletionItem[]
    local complete_items = {
      {
        -- detail not in documentation, should be prepended as code block
        detail = '(method) nvim__id_array_1(arr: any[]): any[]',
        documentation = {
          kind = 'markdown',
          value = [[```lua\nfunction vim.api.nvim__id_array_1(arr: any[])\n  -> any[]\n```]],
        },
        insertText = 'nvim__id_array_1',
        insertTextFormat = 1,
        kind = 3,
        label = 'nvim__id_array_1(arr)',
        sortText = '0001',
      },
      {
        -- detail not in documentation, should be prepended as code block
        detail = '(method) nvim__id_array_2(arr: any[]): any[]',
        documentation = {
          kind = 'markdown',
          value = [[```lua\nfunction vim.api.nvim__id_array_2(arr: any[])\n  -> any[]\n```]],
        },
        insertText = 'nvim__id_array_2',
        insertTextFormat = 1,
        kind = 3,
        label = 'nvim__id_array_2(arr)',
        sortText = '0002',
      },
      {
        -- snippet populated in insertText
        insertText = 'for ${1:i} = ${2:1}, ${3:10, 1} do\n\t$0\nend',
        insertTextFormat = 2,
        kind = 15,
        label = 'for i = ..',
        sortText = '0003',
      },
      {
        -- snippet populated in textEdit.newText
        textEdit = {
          newText = 'for ${1:j} = ${2:1}, ${3:10, 1} do\n\t$0\nend',
          range = {
            start = { character = 0, line = 0 },
            ['end'] = { character = 0, line = 0 },
          },
        },
        insertTextFormat = 2,
        kind = 15,
        label = 'for j = ..',
        sortText = '0004',
      },
      {
        -- detail is in documentation, should not be duplicated
        detail = '_assert_integer',
        documentation = {
          kind = 'plaintext',
          value = [[```lua\nmore doc for vim._assert_integer\n```]],
        },
        insertText = '_assert_integer(${1:x}, ${2:base?})',
        insertTextFormat = 2,
        kind = 3,
        label = '_assert_integer(x, base)',
        sortText = '0005',
      },
    }

    ---@param opts {items:lsp.CompletionItem[], resolved_items:lsp.CompletionItem[]}
    local function run_test(opts)
      local screen = Screen.new(50, 20)
      screen:add_extra_attr_ids({
        [100] = { background = Screen.colors.Plum1, foreground = Screen.colors.Blue },
      })
      local completion_list = {
        isIncomplete = false,
        items = opts.items,
      }
      exec_lua(function()
        vim.o.completeopt = 'menuone,popup'
      end)
      create_server('dummy', completion_list, {
        resolve_result = opts.resolved_items,
      })

      feed('S<C-X><C-O>')
      retry(nil, nil, function()
        local info = exec_lua(function()
          local data = vim.fn.complete_info({ 'selected' })
          if
            not data.preview_winid
            or not vim.api.nvim_win_is_valid(data.preview_winid)
            or not data.preview_bufnr
            or not vim.api.nvim_buf_is_valid(data.preview_bufnr)
          then
            error('preview not ready')
          end
          return table.concat(vim.api.nvim_buf_get_lines(data.preview_bufnr, 0, -1, false), '\n')
        end)
        -- item 1: detail is not in documentation, should be prepended
        neq(nil, info:find('(method) nvim__id_array_1(arr: any[]): any[]', 1, true))
        neq(nil, info:find('function vim.api.nvim__id_array_1', 1, true))
      end)
      screen:expect([[
        nvim__id_array_1^                                  |
        {12:nvim__id_array_1 Function }{100:(method) nvim__id_array}{1: }|
        {4:nvim__id_array_2 Function }{100:_1(arr: any[]): any[]}{4:  }{1: }|
        {4:for i = ..       Snippet  }{100:lua\nfunction vim.api.n}{1: }|
        {4:for j = ..       Snippet  }{100:vim__id_array_1(arr: an}{1: }|
        {4:_assert_integer  Function }{100:y[])\n  -> any[]\n}{4:     }{1: }|
        {1:~                                                 }|*13
        {5:-- INSERT --}                                      |
      ]])
      feed('<C-N>')
      screen:expect([[
        nvim__id_array_2^                                  |
        {4:nvim__id_array_1 Function }{100:(method) nvim__id_array}{1: }|
        {12:nvim__id_array_2 Function }{100:_2(arr: any[]): any[]}{4:  }{1: }|
        {4:for i = ..       Snippet  }{100:lua\nfunction vim.api.n}{1: }|
        {4:for j = ..       Snippet  }{100:vim__id_array_2(arr: an}{1: }|
        {4:_assert_integer  Function }{100:y[])\n  -> any[]\n}{4:     }{1: }|
        {1:~                                                 }|*13
        {5:-- INSERT --}                                      |
      ]])
      feed('<C-N>')
      screen:expect([[
        for i = ..^                                        |
        {4:nvim__id_array_1 Function }{100:for i = 1, 10, 1 do}{1:     }|
        {4:nvim__id_array_2 Function }{100:        }{4:           }{1:     }|
        {12:for i = ..       Snippet  }{100:end}{4:                }{1:     }|
        {4:for j = ..       Snippet  }{1:                        }|
        {4:_assert_integer  Function }{1:                        }|
        {1:~                                                 }|*13
        {5:-- INSERT --}                                      |
      ]])
      feed('<C-N>')
      screen:expect([[
        for j = ..^                                        |
        {4:nvim__id_array_1 Function }{100:for j = 1, 10, 1 do}{1:     }|
        {4:nvim__id_array_2 Function }{100:        }{4:           }{1:     }|
        {4:for i = ..       Snippet  }{100:end}{4:                }{1:     }|
        {12:for j = ..       Snippet  }{1:                        }|
        {4:_assert_integer  Function }{1:                        }|
        {1:~                                                 }|*13
        {5:-- INSERT --}                                      |
      ]])
      feed('<C-N>')
      retry(nil, nil, function()
        local info, ts_highlight, conceallevel = exec_lua(function()
          local data = vim.fn.complete_info({ 'selected' })
          if not data.preview_bufnr or not vim.api.nvim_buf_is_valid(data.preview_bufnr) then
            error('preview not ready')
          end
          return table.concat(vim.api.nvim_buf_get_lines(data.preview_bufnr, 0, -1, false), '\n'),
            vim.b[data.preview_bufnr].ts_highlight or false,
            vim.wo[data.preview_winid].conceallevel
        end)
        neq(nil, info:find('more doc for vim._assert_integer', 1, true))
        local _, count = info:gsub('_assert_integer', '')
        -- item 3: detail '_assert_integer' is in documentation, should not be duplicated
        eq(1, count)
        eq(false, ts_highlight)
        eq(0, conceallevel)
      end)
      screen:expect([[
        _assert_integer(x, base)^                          |
        {4:nvim__id_array_1 Function ```lua\nmore doc for vi}{1: }|
        {4:nvim__id_array_2 Function m._assert_integer\n``` }{1: }|
        {4:for i = ..       Snippet  }{1:                        }|
        {4:for j = ..       Snippet  }{1:                        }|
        {12:_assert_integer  Function }{1:                        }|
        {1:~                                                 }|*13
        {5:-- INSERT --}                                      |
      ]])
    end

    it('when server supports completionItem/resolve', function()
      run_test({ items = incomplete_items, resolved_items = complete_items })
    end)

    it('when server does not support completionItem/resolve', function()
      run_test({ items = complete_items })
    end)
  end)

  it('ignores non-LSP completion metadata on acceptance', function()
    n.command('set completeopt=menuone,noselect')
    create_server('dummy', {})
    feed('i')
    exec_lua(function()
      vim.v.errmsg = ''
      vim.fn.complete(1, { { word = 'other', user_data = { nvim = {} } } })
    end)
    wait_for_pum()
    feed('<C-n><C-y>')
    eq('other', n.api.nvim_get_current_line())
    eq('', n.api.nvim_get_vvar('errmsg'))
  end)

  it('omnifunc works without enable() #38252', function()
    local completion_list = {
      isIncomplete = false,
      items = {
        { label = 'hello' },
        -- Empty snippet insertText must fall back to the label on acceptance.
        { label = 'hallo', insertText = '', insertTextFormat = 2 },
      },
    }
    local client_id = exec_lua(function()
      local server = _G._create_server({
        capabilities = {
          completionProvider = {
            triggerCharacters = { '.' },
          },
        },
        handlers = {
          ['textDocument/completion'] = function(_, _, callback)
            callback(nil, completion_list)
          end,
        },
      })
      local bufnr = vim.api.nvim_get_current_buf()
      local id = vim.lsp.start({
        name = 'dummy',
        cmd = server.cmd,
      })
      if id then
        vim.lsp.buf_attach_client(bufnr, id)
        vim.bo[bufnr].omnifunc = 'v:lua.vim.lsp.omnifunc'
      end
    end)
    feed('ih<C-x><C-o>')
    wait_for_pum()
    feed('<C-y>')
    eq('hallo', n.api.nvim_get_current_line())
  end)

  it('CompletionItem.preselect', function()
    local completion_list = {
      isIncomplete = false,
      items = {
        { label = 'aaa' },
        { label = 'zzz', preselect = true },
        { label = 'mmm' },
      },
    }
    exec_lua(function()
      vim.o.completeopt = 'menuone,noselect,preselect'
    end)
    create_server('dummy', completion_list)
    feed('i<C-x><C-o>')
    wait_for_pum()
    eq(
      2,
      exec_lua(function()
        return vim.fn.complete_info({ 'selected' }).selected
      end)
    )
  end)

  it('support commitCharacters', function()
    n.command('set completeopt=menuone,menu,noinsert')
    -- from typescript-language-server
    local completion_list = {
      isIncomplete = false,
      items = {
        {
          -- Only whole characters are kept: '\0' and '\169x' are dropped, '=>' becomes '='.
          commitCharacters = { '.', ',', ';', '\0', '(', '=>', '\169x' },
          data = {
            cacheId = 1,
          },
          filterText = '.bar',
          kind = 2,
          label = 'bar',
          sortText = '11',
          textEdit = {
            newText = '.bar',
            range = {
              ['end'] = {
                character = 2,
                line = 0,
              },
              start = {
                character = 1,
                line = 0,
              },
            },
          },
        },
      },
    }
    create_server('dummy', completion_list, { trigger_chars = { '.' } })
    feed('Sf.')
    wait_for_pum()
    feed('(')
    eq('f.bar(', n.api.nvim_get_current_line())

    n.command('set completeopt+=noselect')
    feed('<ESC>Sf.')
    wait_for_pum()
    feed('(')
    eq('f.(', n.api.nvim_get_current_line())

    -- Test that a dropped fragment did not leak: 'x' must not commit, '=' must.
    n.command('set completeopt=menuone,menu,noinsert')
    feed('<ESC>Sf.')
    wait_for_pum()
    feed('x')
    eq('f.x', n.api.nvim_get_current_line())

    feed('<ESC>Sf.')
    wait_for_pum()
    feed('=')
    eq('f.bar=', n.api.nvim_get_current_line())
  end)

  it('keeps an item that starts after the session column, also for "."', function()
    local completion_list = {
      isIncomplete = false,
      items = {
        {
          label = 'field2',
          textEdit = {
            newText = 'field2',
            range = {
              start = { character = 4, line = 0 },
              ['end'] = { character = 7, line = 0 },
            },
          },
        },
      },
    }
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
      vim.bo.iskeyword = vim.bo.iskeyword .. ',.'
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { '', '' })
    end)
    local client_id = create_server('dummy', completion_list)
    feed('iobj.fie<C-x><C-o>')
    wait_for_pum()
    feed('<C-y><Esc>')
    eq('obj.field2', n.api.nvim_get_current_line())
    feed('j.')
    eq({ 'obj.field2', 'obj.field2' }, n.api.nvim_buf_get_lines(0, 0, -1, true))
    assert_cleanup_after_detach(client_id)
  end)

  it('drops its session when the buffer is left mid-completion', function()
    local client_id = create_server('dummy', {
      isIncomplete = false,
      items = { { label = 'hello' } },
    })
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
      _G.other = vim.api.nvim_create_buf(true, true)
    end)
    feed('ihe<C-x><C-o>')
    wait_for_pum()
    exec_lua(function()
      vim.api.nvim_set_current_buf(_G.other)
    end)
    n.poke_eventloop()
    exec_lua(function()
      vim.api.nvim_set_current_buf(vim.fn.bufnr('#'))
    end)

    feed('<Esc>ohello<CR>he<C-n>')
    wait_for_pum()
    eq('keyword', n.fn.complete_info({ 'mode' }).mode)
    assert_cleanup_after_detach(client_id)
  end)

  it('takes back a match at the session column when typing continues', function()
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone'
    end)
    local client_id = create_server('dummy', {
      isIncomplete = false,
      items = { { label = 'hello' }, { label = 'helper' } },
    })
    feed('ih<C-x><C-o>')
    wait_for_pum()
    eq('hello', n.api.nvim_get_current_line())
    feed('e')
    retry(nil, nil, function()
      eq(2, #n.fn.complete_info({ 'matches' }).matches)
    end)
    assert_cleanup_after_detach(client_id)
  end)

  it('keeps the cached list when publishing takes over omni completion', function()
    local completion_list = {
      isIncomplete = true,
      items = { { label = 'hello' }, { label = 'hercules' } },
    }
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noinsert'
    end)
    local client_id = exec_lua(function(list)
      _G.rounds = 0
      local server = _G._create_server({
        capabilities = { completionProvider = {} },
        handlers = {
          ['textDocument/completion'] = function(_, _, callback)
            _G.rounds = _G.rounds + 1
            callback(nil, list)
          end,
        },
      })
      local id = vim.lsp.start({ name = 'dummy', cmd = server.cmd })
      vim.lsp.completion.enable(true, id, 0)
      return id
    end, completion_list)

    feed('ihe<C-x><C-o>')
    wait_for_pum()
    local before = exec_lua('return _G.rounds')
    feed('<BS>')
    retry(nil, nil, function()
      assert(exec_lua('return _G.rounds') > before)
    end)
    eq('h', n.api.nvim_get_current_line())
    assert_cleanup_after_detach(client_id)
  end)
end)

describe("vim.lsp.completion: omnifunc + 'autocomplete'", function()
  before_each(function()
    clear()
    exec_lua(create_server_definition)
    exec_lua(function()
      -- enable buffer and omnifunc autocompletion
      -- omnifunc will be the lsp omnifunc
      vim.o.complete = '.,o'
      vim.o.autocomplete = true
    end)

    local completion_list = {
      isIncomplete = false,
      items = {
        { label = 'hello' },
        { label = 'hallo' },
      },
    }
    create_server('dummy', completion_list, { delay = 50 })
  end)

  local function assert_matches(expected)
    retry(nil, nil, function()
      local matches = vim.tbl_map(function(m)
        return m.word
      end, exec_lua('return vim.fn.complete_info({ "matches" })').matches)
      eq(expected, matches)
    end)
  end

  it('merges with other completions', function()
    exec_lua(function()
      vim.o.complete = 'o,b'
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, 'Xcompletion-source')
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'hillo' })
    end)
    feed('ih')
    assert_matches({ 'hillo', 'hallo', 'hello' })
    eq('Xcompletion-source', exec_lua('return vim.fn.complete_info({ "items" })').items[1].menu)
  end)

  it('fuzzy matches without duplication', function()
    -- wait for one completion request to start and then request another before
    -- the first one finishes, then wait for both to finish
    feed('ihillo<cr>h')
    vim.uv.sleep(1)
    feed('e')

    assert_matches({ 'hello' })
  end)
end)

describe('vim._core.completion.source.keyword', function()
  before_each(clear)

  --- Labels the source answers with at the cursor.
  --- @return string[]
  local function labels()
    return exec_lua(function()
      local line = vim.api.nvim_get_current_line()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local res = require('vim._core.completion.source').keyword.handler({
        bufnr = vim.api.nvim_get_current_buf(),
        line = line,
        col = cursor[2],
        position = { line = cursor[1] - 1, character = vim.str_utfindex(line, 'utf-16', cursor[2]) },
        context = { triggerKind = 1 },
        cancelled = function()
          return false
        end,
        drifted = function()
          return false
        end,
        yield = function() end,
      })
      return vim.tbl_map(function(item)
        return item.label
      end, res.items)
    end)
  end

  it("infers case under 'smartcase' when 'infercase' is set", function()
    n.command('set ignorecase smartcase infercase')
    n.api.nvim_buf_set_lines(0, 0, -1, true, { 'fooBar' })
    feed('GoFO')
    eq({ 'FOOBAR' }, labels())
  end)

  it("applies 'smartcase' by the 'infercase' of the buffer it searches", function()
    n.command('set ignorecase smartcase')
    exec_lua(function()
      local other = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(other, 0, -1, true, { 'foo2' })
    end)
    n.command('setlocal infercase')
    n.api.nvim_buf_set_lines(0, 0, -1, true, { 'foo1' })
    feed('GoF')
    eq({ 'Foo1' }, labels())
  end)
end)

describe('vim._core.completion trigger characters', function()
  before_each(clear)

  it('asks only the sources that declared the character', function()
    exec_lua(function()
      vim.o.completeopt = 'menu,menuone,noselect'
      local completion = require('vim._core.completion')
      completion.enable(true, 0, {
        sources = {
          completion.source.keyword,
          {
            name = 'colon',
            trigger = { characters = { ':' } },
            handler = function()
              return { isIncomplete = false, items = { { label = 'emoji' } } }
            end,
          },
        },
      })
    end)
    n.api.nvim_buf_set_lines(0, 0, -1, true, { 'hello world' })
    feed('Go:')
    retry(nil, nil, function()
      eq(
        { 'emoji' },
        vim.tbl_map(function(m)
          return m.word
        end, n.fn.complete_info({ 'matches' }).matches)
      )
    end)
  end)
end)
