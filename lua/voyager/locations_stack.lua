---Locations stack manager.
---@class LocationsStack
local LocationsStack = {}

local loc_stack = {}

---Push new locations for provided lsp method.
---@param parent table Original location.
---@param method str Lsp method used to obtain new locatiosn.
---@param locations any New locations returened by lsp.
LocationsStack.push_locations = function(parent method, locations)
  if locations then
    vim.tbl_extend('force', loc_stack, locations)
  end
end

---Pop lastly added locations from stack.
LocationsStack.pop = function()
  loc_stack[#loc_stack] = nil
end

---Get locations from last lsp method call.
LocationsStack.get_last_locations = function()
  return loc_stack[#loc_stack]
end


return LocationsStack
