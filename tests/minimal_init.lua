local root = vim.fn.getcwd()

assert(vim.env.VOYAGER_TEST_ROOT == root, "tests must run through make test-unit")
local paths = {
  root,
  root .. "/.deps/plenary.nvim",
  root .. "/.deps/nui.nvim",
  vim.env.VIMRUNTIME,
}
-- Keep the bundled treesitter parser directories (lib/nvim) so the symbol
-- resolution fallback stays testable.
for _, entry in ipairs(vim.api.nvim_list_runtime_paths()) do
  if entry ~= vim.env.VIMRUNTIME and vim.uv.fs_stat(entry .. "/parser") then
    table.insert(paths, entry)
  end
end
vim.opt.runtimepath = table.concat(paths, ",")
vim.opt.packpath = ""
vim.opt.loadplugins = false
vim.opt.shadafile = "NONE"
vim.opt.swapfile = false

vim.cmd("runtime plugin/plenary.vim")
require("plenary.busted")
