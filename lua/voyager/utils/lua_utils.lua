---@class LuaUtils
---Utils for lua related stuff
local LuaUtils = {}

LuaUtils.table_sort_keys = function(t)
  local keys = {}
  for key in pairs(t) do
    table.insert(keys, key)
  end
  table.sort(keys)
  return keys
end

return LuaUtils
