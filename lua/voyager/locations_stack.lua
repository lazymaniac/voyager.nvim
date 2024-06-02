---Locations stack manager.
---@class LocationsStack
local LocationsStack = {}

local locations_stack = {}

---Push new locations for provided lsp method.
---@param parent table Original location.
---@param method str Lsp method used to obtain new locatiosn.
---@param locations any New locations returened by lsp.
LocationsStack.push_locations = function(parent, method, locations)
  if locations then
    locations_stack:insert({
      parent = parent,
      method = method,
      locations = locations,
    })
  end
end

---Pop lastly added locations from stack.
LocationsStack.pop = function()
  locations_stack[#locations_stack] = nil
end

---Get locations from last lsp method call.
LocationsStack.get_last_locations = function()
  return locations_stack[#locations_stack]
end

return LocationsStack
