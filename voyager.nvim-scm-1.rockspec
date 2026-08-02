package = "voyager.nvim"
version = "scm-1"
source = {
  url = "git+https://github.com/lazymaniac/voyager.nvim.git",
}
description = {
  summary = "Persistent branching LSP navigation flows for Neovim",
  detailed = "Explore LSP destinations as a branching tree, annotate nodes, and save project-local flows.",
  homepage = "https://github.com/lazymaniac/voyager.nvim",
  license = "MIT",
}
dependencies = {
  "lua >= 5.1",
  "nui.nvim == 0.4.0-1",
}
build = {
  type = "builtin",
  modules = {
    ["voyager"] = "lua/voyager.lua",
    ["voyager.config"] = "lua/voyager/config.lua",
    ["voyager.runtime"] = "lua/voyager/runtime.lua",
    ["voyager.locator"] = "lua/voyager/locator.lua",
    ["voyager.flow"] = "lua/voyager/flow.lua",
    ["voyager.schema"] = "lua/voyager/schema.lua",
    ["voyager.store"] = "lua/voyager/store.lua",
    ["voyager.keymaps"] = "lua/voyager/keymaps.lua",
    ["voyager.sidebar"] = "lua/voyager/sidebar.lua",
    ["voyager.session"] = "lua/voyager/session.lua",
    ["voyager.lsp"] = "lua/voyager/lsp.lua",
    ["voyager.lsp.actions"] = "lua/voyager/lsp/actions.lua",
    ["voyager.lsp.normalize"] = "lua/voyager/lsp/normalize.lua",
    ["voyager.lsp.request_group"] = "lua/voyager/lsp/request_group.lua",
    ["voyager.lsp.call_hierarchy"] = "lua/voyager/lsp/call_hierarchy.lua",
    ["voyager.lsp.presentation"] = "lua/voyager/lsp/presentation.lua",
  },
  copy_directories = { "plugin", "doc" },
}
