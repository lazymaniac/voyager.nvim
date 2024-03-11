-- main module file
local lsp = require("voyager.lsp")
local ui = require("voyager.ui")

---@class Config
---@field opt string Your config option
local config = {
  opt = "Hello!",
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

M.open_voyager = function ()
  ui.open_voyager()
end

M.close_voyager = function ()
  ui.close_voyager()
end

return M
