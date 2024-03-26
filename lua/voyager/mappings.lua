---@class Mappings
---Utility class to manipulate global and voyager mappings
local M = {}

local mode = "n"

---Table of keys used by plugin to operate on codebase
local local_mappings = {
  def = { lhs = "gd" },
  ref = { lhs = "gr" },
  impl = { lhs = "gI" },
  type_def = { lhs = "gD" },
  inc = { lhs = "gC" },
  out = { lhs = "gG" },
}

---Table of global mappings which are in conflict with plugin mappings. Used to restore them after voyager session is closed or buffer is switched.
local global_mappings = {}

---Function to find global mapping which may be in conflict with Voyager mappings. If global mapping exists it will be stored in table for restoring after session is closed.
M.find_conflicting_global_mappings = function()
  --NOTE: Possibly store this value in global variable to reduce calls to vim api
  local mappings = vim.api.nvim_get_keymap(mode)

  for _, lhs in ipairs(local_mappings) do
    for _, mapping in ipairs(mappings) do
      if mapping.lhs == lhs then
        table.insert(global_mappings, mapping)
      end
    end
  end
end

M.restore_global_mappings = function()
  for _, mapping in ipairs(global_mappings) do
    vim.api.nvim_set_keymap(mode, mapping.lhs, mapping.rhs, {
      noremap = (mapping.noremap == 1),
      silent = (mapping.silent == 1),
      expr = (mapping.expr == 1),
      script = (mapping.script == 1),
      nowait = (mapping.nowait == 1),
    })
  end
end

M.get_local_mapping = function(action)
  return local_mappings[action]
end

return M
