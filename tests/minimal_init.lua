local root = vim.fn.getcwd()

assert(vim.env.VOYAGER_TEST_ROOT == root, "tests must run through make test-unit")
vim.opt.runtimepath = table.concat({
  root,
  root .. "/.deps/plenary.nvim",
  root .. "/.deps/nui.nvim",
  vim.env.VIMRUNTIME,
}, ",")
vim.opt.packpath = ""
vim.opt.loadplugins = false
vim.opt.shadafile = "NONE"
vim.opt.swapfile = false

vim.cmd("runtime plugin/plenary.vim")
require("plenary.busted")
