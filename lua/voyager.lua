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

M.get_references = function()
  print("get_references")

  lsp.get_references(function(locations)
    for client_id, result in pairs(locations) do
      vim.print(result)
      local client = assert(vim.lsp.get_client_by_id(client_id))
      local items = vim.lsp.util.locations_to_items(result.result, client.offset_encoding)
      print("item", items[1].text)
      vim.lsp.util.jump_to_location(result.result[1], client.offset_encoding, false)
    end
  end)
end

M.open_vyager = function ()
  print("open layout")
  ui.build_layout()
end

return M
