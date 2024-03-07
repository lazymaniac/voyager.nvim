-- main module file
local lsp = require("lua.voyager.lsp")

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

M.hello = function()
  return lsp.my_first_function(M.config.opt)
end

M.get_references = function ()
  lsp.get_references(function (retval)
    vim.print(retval)
  end)
end

return M
