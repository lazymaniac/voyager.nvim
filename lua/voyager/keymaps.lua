---Mode for all mappings
local mode = "n"

---Table of keys used by plugin to operate on codebase
local local_keymap = {
  def = "gd",
  ref = "gr",
  impl = "gI",
  type_def = "gD",
  inc = "gC",
  out = "gG",
}

---Table of global mappings which are in conflict with plugin mappings. Used to restore them after voyager session is closed or buffer is switched.
local global_keymaps = {}

---@class Mappings
---Utility class to manipulate global and voyager mappings
local M = {}

---Set mappings provided by user
M.set_keymaps = function(user_keymap)
  if user_keymap then
    local_keymap = user_keymap
  end
end

---Function to find global mapping which may be in conflict with Voyager mappings. If global mapping exists it will be stored in table for restoring after session is closed.
M.find_conflicting_global_keymaps = function()
  local normal_mode_keymaps = vim.api.nvim_buf_get_keymap(0, mode)

  for _, keymap in ipairs(normal_mode_keymaps) do
    for _, lhs in pairs(local_keymap) do
      if keymap.lhs == lhs then
        table.insert(global_keymaps, keymap)
      end
    end
  end
end

M.restore_global_keymaps = function()
  for _, keymap in ipairs(global_keymaps) do
    local rhs = keymap.callback or keymap.rhs -- Check if rhs is null then use callback
    vim.keymap.set(mode, keymap.lhs, rhs, {
      buffer = keymap.buffer,
      desc = keymap.desc,
      noremap = (keymap.noremap == 1),
      silent = (keymap.silent == 1),
      expr = (keymap.expr == 1),
      script = (keymap.script == 1),
      nowait = (keymap.nowait == 1),
    })
  end
end

M.get_local_mapping = function(action)
  return local_keymap[action]
end

return M
