local M = {}

--- Parse option string based on list type
--- @param str string The option string to parse
--- @param list_type 'comma'|'onecomma'|'commacolon'|'onecommacolon'|'flags'|'flagscomma'
--- @param validator? table Optional validators for keys/values
---
--- @return table result
--- @return string? error message if parsing failed
function M.parse_list_option(str, list_type, validator)
  if str == '' then
    return {}, nil
  end

  validator = validator or {}
  local result = {}

  -- Determine iterator and parsing mode
  --- @type fun():string?
  local iter
  --- @type boolean
  local parse_kv

  if list_type:match('^comma') then
    iter = vim.gsplit(str, ',', { plain = true, trimempty = true })
    parse_kv = list_type:match('colon$') ~= nil
  elseif list_type:match('^flags') then
    local sep = list_type == 'flagscomma' and ',' or ''
    iter = sep == '' and str:gmatch('.') or vim.gsplit(str, sep, { plain = true, trimempty = true })
    parse_kv = false
  else
    return result, string.format('Unknown list type: %s', list_type)
  end

  -- Parse each item
  for part in iter do
    if parse_kv then
      local key, value = part:match('^([^:]+):(.+)$')
      if not key then
        return result, string.format('Invalid format: %s', part)
      end

      if validator.keys and not vim.list_contains(validator.keys, key) then
        return result, string.format('Unknown option: %s', key)
      end

      if validator.parsers and validator.parsers[key] then
        --- @type any, string?
        local parsed, err = validator.parsers[key](value)
        if err then
          return result, err
        end
        value = parsed
      end

      result[key] = value
    else
      if validator.value then
        --- @type boolean, string?
        local ok, err = validator.value(part)
        if not ok then
          return result, err
        end
      elseif validator.flags and not vim.list_contains(validator.flags, part) then
        return result, string.format('Invalid flag: %s', part)
      end

      table.insert(result, part)
    end
  end

  return result
end

--- Parse previewpopup option and return height, width as array
--- @param str string
---
--- @return table<integer, integer> array with [height, width]
function M.parse_previewpopup_values(str)
  local result, err = M.parse_list_option(str, 'commacolon', {
    keys = { 'height', 'width' },
    parsers = {
      height = function(v)
        local n = tonumber(v)
        if not n or n < 1 or math.floor(n) ~= n then
          return nil, ' previewpopup: height must be a positive integer'
        end
        return n
      end,
      width = function(v)
        local n = tonumber(v)
        if not n or n < 1 or math.floor(n) ~= n then
          return nil, ' previewpopup: width must be a positive integer'
        end
        return n
      end,
    },
  })

  if err then
    error(err)
  end

  return { result.height or 0, result.width or 0 }
end

return M
