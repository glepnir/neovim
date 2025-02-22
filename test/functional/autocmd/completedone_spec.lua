local t = require('test.testutil')
local n = require('test.functional.testnvim')()

local clear = n.clear
local command = n.command
local call = n.call
local feed = n.feed
local eval = n.eval
local eq = t.eq
local exec = n.exec

describe('CompleteDone', function()
  before_each(clear)

  describe('sets v:event.reason', function()
    before_each(function()
      clear()
      command('autocmd CompleteDone * let g:donereason = v:event.reason')
      feed('i')
      call('complete', call('col', '.'), { 'foo', 'bar' })
    end)

    it('accept', function()
      feed('<C-y>')
      eq('accept', eval('g:donereason'))
    end)
    describe('cancel', function()
      it('on <C-e>', function()
        feed('<C-e>')
        eq('cancel', eval('g:donereason'))
      end)
      it('on non-keyword character', function()
        feed('<Esc>')
        eq('cancel', eval('g:donereason'))
      end)
      it('when overridden by another complete()', function()
        call('complete', call('col', '.'), { 'bar', 'baz' })
        eq('cancel', eval('g:donereason'))
      end)
    end)
  end)

  it('Do not set the reason when preparing completion with space', function()
    exec([[
      func Omni_test(findstart, base)
        if a:findstart
          return col(".")
        endif
        call timer_start(100, {->complete(col('.'), [#{word: "foo"}, #{word: "bar"}])})
        return -2
      endfunc
      set omnifunc=Omni_test
      let g:reason_list = []
      autocmd CompleteDone * call add(g:reason_list, get(v:event, 'reason', ''))
    ]])
    command('lua vim.wait(150)')
    feed('S<C-X><C-O><C-Y>')
    vim.uv.sleep(150)
    eq({''}, eval('g:reason_list'))
    eq(1, eval('pumvisible()'))
  end)
end)
