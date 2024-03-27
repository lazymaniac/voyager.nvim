-- main module file
local ui = require("voyager.ui")

---@class Config
---@field opt string Your config option
local config = {
  mappings = {
    def = "gd", -- Definition
    ref = "gr", -- References
    impl = "gI", -- Implementation
    type_def = "gD", -- Type Definition
    inc = "gC", -- Incoming Calls
    out = "gG", -- Outgoing Calls
  },
}

---@class VoyagerModule
local M = {}

---@type Config
M.config = config

---@param args Config?
-- you can define your setup function here. Usually configurations can be merged, accepting outside params and
-- you can also put some validation here for those.
M.setup = function(args)
  M.config = vim.tbl_deep_extend("force", M.config, args or {})
end

M.open_voyager = function()
  ui.open_voyager(M.config)
end

M.close_voyager = function()
  ui.close_voyager()
end

return M
