local mysql_store = require("mysql_store")
local memory_store = require("memory_store")
local auth = require("auth")

local function main()
  local value = "account"
  mysql_store.save(value)
  memory_store.save(value)
  return auth.authorize(value)
end

return { main = main }
