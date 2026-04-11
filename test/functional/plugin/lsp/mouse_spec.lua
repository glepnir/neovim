local t = require('test.testutil')
local n = require('test.functional.testnvim')()

local clear, command = n.clear, n.command
local exec_lua = n.exec_lua
local eq = t.eq
local api = n.api

describe('vim.lsp.mouse', function()
  before_each(function()
    clear()
    exec_lua(function()
      vim.o.mousemoveevent = true
    end)
  end)

  after_each(function()
    exec_lua(function()
      vim.lsp.mouse.enable(false)
    end)
  end)

  describe('enable()', function()
    it('works', function()
      eq(false, exec_lua('return vim.lsp.mouse.is_enabled()'))

      exec_lua('vim.lsp.mouse.enable()')
      eq(true, exec_lua('return vim.lsp.mouse.is_enabled()'))

      exec_lua('vim.lsp.mouse.enable(false)')
      eq(false, exec_lua('return vim.lsp.mouse.is_enabled()'))

      exec_lua('vim.lsp.mouse.enable()')
      eq(true, exec_lua('return vim.lsp.mouse.is_enabled()'))

      exec_lua(function()
        vim.lsp.mouse.enable(true, { delay = 100, close_events = { 'BufLeave' } })
      end)
      eq(true, exec_lua('return vim.lsp.mouse.is_enabled()'))
    end)

    it('notifies when mousemoveevent is not set', function()
      command('set nomousemoveevent')
      eq(
        "vim.lsp.mouse: requires 'mousemoveevent'.",
        n.exec_capture([[lua vim.lsp.mouse.enable(true)]])
      )
    end)

    it('validates arguments', function()
      eq(
        false,
        exec_lua(function()
          return pcall(vim.lsp.mouse.enable, 'yes')
        end)
      )
    end)
  end)

  describe('<MouseMove> keymap', function()
    it('sets keymap on enable', function()
      exec_lua('vim.lsp.mouse.enable()')
      eq(false, exec_lua("return vim.fn.maparg('<MouseMove>', 'n')") == '')
    end)

    it('removes keymap on disable', function()
      exec_lua('vim.lsp.mouse.enable()')
      exec_lua('vim.lsp.mouse.enable(false)')
      eq('', exec_lua("return vim.fn.maparg('<MouseMove>', 'n')"))
    end)

    it('preserves existing user <MouseMove> mapping', function()
      exec_lua(function()
        vim.keymap.set('n', '<MouseMove>', function()
          print('hello')
        end)
        vim.lsp.mouse.enable()
      end)

      -- disable should restore the user's original mapping
      exec_lua('vim.lsp.mouse.enable(false)')
      eq(false, exec_lua("return vim.fn.maparg('<MouseMove>', 'n')") == '')
    end)

    it('sets keymap for both n and v modes', function()
      exec_lua('vim.lsp.mouse.enable()')
      eq(false, exec_lua("return vim.fn.maparg('<MouseMove>', 'n')") == '')
      eq(false, exec_lua("return vim.fn.maparg('<MouseMove>', 'v')") == '')
    end)
  end)

  describe('close_events autocmd', function()
    it('close_events autocmds when enabled and disable', function()
      exec_lua('vim.lsp.mouse.enable()')
      local autocmds = exec_lua(function()
        return #vim.api.nvim_get_autocmds({ group = 'nvim.lsp.mouse' })
      end)
      eq(true, autocmds > 0)

      exec_lua('vim.lsp.mouse.enable(false)')
      autocmds = exec_lua(function()
        return #vim.api.nvim_get_autocmds({ group = 'nvim.lsp.mouse' })
      end)
      eq(0, autocmds)

      exec_lua('vim.lsp.mouse.enable(true, { close_events = {} })')
      autocmds = exec_lua(function()
        return #vim.api.nvim_get_autocmds({ group = 'nvim.lsp.mouse' })
      end)
      eq(0, autocmds)
    end)
  end)

  describe('diagnostic float', function()
    it('opens diagnostic float when mouse hovers over diagnostic', function()
      local bufnr = api.nvim_get_current_buf()
      api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'hello world' })
      exec_lua(function()
        vim.diagnostic.set(
          vim.api.nvim_create_namespace('test'),
          vim.api.nvim_get_current_buf(),
          { { lnum = 0, col = 0, end_lnum = 0, end_col = 5, message = 'err', severity = 1 } }
        )
        vim.lsp.mouse.enable(true, { delay = 0 })
      end)
      api.nvim_input_mouse('move', '', '', 0, 0, 5)
      n.poke_eventloop()
      local has_float = false
      local errmsg = {}
      for _, w in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_get_config(w).relative ~= '' then
          has_float = true
          errmsg = api.nvim_buf_get_lines(api.nvim_win_get_buf(w), 0, -1, false)
          break
        end
      end
      eq(true, has_float)
      eq({ 'Diagnostics:', 'err' }, errmsg)
    end)
  end)
end)
