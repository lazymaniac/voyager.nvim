-- main module file
local ui = require("voyager.ui")

---@class Config
---@field keymaps table Keymaps cofniguraiton
local config = {
  keymaps = {
    definition = { lhs = "gd", desc = "Goto Definition <gd>" },
    references = { lhs = "gr", desc = "Goto References <gr>" },
    implementation = { lhs = "gI", desc = "Goto Implementation <gI>" },
    type_definitions = { lhs = "gD", desc = "Goto Type Definition <gD>" },
    incoming_calls = { lhs = "gC", desc = "Incoming Calls <gC>" },
    outgoing_calls = { lhs = "gG", desc = "Outgoing Calls <gG>" },
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
