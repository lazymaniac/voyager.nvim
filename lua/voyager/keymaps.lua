---Mode for all mappings
local mode = "n"

---Table of keys used by plugin to operate on codebase
local local_keymaps = {
  definition = { lhs = "gd", desc = "Goto Definition <gd>" },
  references = { lhs = "gr", desc = "Goto References <gr>" },
  implementation = { lhs = "gI", desc = "Goto Implementation <gI>" },
  type_definition = { lhs = "gD", desc = "Goto Type Definition <gD>" },
  incoming_calls = { lhs = "gC", desc = "Incoming Calls <gC>" },
  outgoing_calls = { lhs = "gG", desc = "Outgoing Calls <gG>" },
}

---Table of global mappings which are in conflict with plugin mappings. Used to restore them after voyager session is closed or buffer is switched.
local global_keymaps = {}

---@class Keymaps
---Utility class to manipulate global and voyager mappings
local Keymaps = {}

---Set mappings provided by user
Keymaps.set_keymaps_from_config = function(config_keymaps)
  if config_keymaps then
    local_keymaps = config_keymaps
  end
end

---Function to find global mapping which may be in conflict with Voyager mappings. If global mapping exists it will be stored in table for restoring after session is finished.
Keymaps.find_conflicting_global_keymaps = function()
  local normal_mode_keymaps = vim.api.nvim_buf_get_keymap(0, mode)

  for _, keymap in ipairs(normal_mode_keymaps) do
    for _, local_keymap in pairs(local_keymaps) do
      if keymap.lhs == local_keymap.lhs then
        table.insert(global_keymaps, keymap)
      end
    end
  end
end

Keymaps.restore_global_keymaps = function()
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

Keymaps.get_local_keymap = function(action)
  return local_keymaps[action]
end

return Keymaps
