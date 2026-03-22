-- Test script for vim.completion
-- Usage: nvim -u NONE -l test_completion.lua
-- Or from inside nvim:  :source test_completion.lua
local completion = require('vim._core.completion')
vim.opt.cot = 'menu,menuone,noinsert'

-- add a source that uses vim.fn.getcompletion
local cmd_source = completion.source.add({
  name = 'vim_cmd',
  priority = 1000,
  keyword_pattern = [[\w\+]],
  refresh = 'never',
  get = function(ctx, sink)
    local items = vim.fn.getcompletion(ctx.prefix, 'command')
    for _, word in ipairs(items) do
      sink.add({ word = word, kind = 'Cmd' })
    end
    sink.done()
  end,
})

-- add a buffer-word source
local buf_source = completion.source.add({
  name = 'buffer',
  priority = 100,
  refresh = 'never',
  get = function(ctx, sink)
    local lines = vim.api.nvim_buf_get_lines(ctx.bufnr, 0, -1, false)
    local seen = {}
    for _, line in ipairs(lines) do
      for word in line:gmatch('%w%w%w+') do
        if not seen[word] then
          seen[word] = true
          sink.add({ word = word, kind = 'Text' })
        end
      end
    end
    sink.done()
  end,
})

-- add a slow source to test progressive display
local slow_source = completion.source.add({
  name = 'slow',
  priority = 500,
  timeout = 3000,
  refresh = 'never',
  get = function(ctx, sink)
    -- Simulate 200ms delay
    local done = false
    local timer = assert(vim.uv.new_timer())
    timer:start(
      200,
      0,
      vim.schedule_wrap(function()
        timer:close()
        if ctx.cancelled() then
          return
        end
        for i = 1, 10 do
          sink.add({ word = ctx.prefix .. '_slow_' .. i, kind = 'Lazy', menu = '[slow]' })
        end
        sink.done()
      end)
    )

    return function()
      if not done then
        done = true
        if timer:is_active() and not timer:is_closing() then
          timer:stop()
          timer:close()
        end
      end
    end
  end,
})

-- Enable on current buffer
completion.enable(true, 0, {
  sources = { cmd_source, buf_source, slow_source },
  autotrigger = true,
})

-- Debug logging
completion.set_log_level('debug')

-- Helper to dump log
vim.api.nvim_create_user_command('CmpLog', function()
  for _, line in ipairs(completion.get_log()) do
    print(line)
  end
end, {})

-- Helper to check status
vim.api.nvim_create_user_command('CmpStatus', function()
  print('enabled:', completion.is_enabled(0))
  print('sources:', #completion.source.get())
  for _, h in ipairs(completion.source.get()) do
    print('  ', h)
  end
end, {})

print('vim.completion test loaded.')
print('  Enter insert mode and type to test.')
print('  :CmpLog   — show engine log')
print('  :CmpStatus — show added sources')
