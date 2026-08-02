local mysql_store = require("mysql_store")
local memory_store = require("memory_store")

local function authorize(value)
  local mysql = mysql_store.save(value)
  local memory = memory_store.save(value)
  return mysql ~= "" and memory ~= ""
end

return { authorize = authorize }
