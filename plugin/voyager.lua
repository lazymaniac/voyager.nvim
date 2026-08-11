local Voyager = require("voyager")

require("voyager.sidebar").setup_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("VoyagerHighlights", { clear = true }),
  callback = function()
    require("voyager.sidebar").setup_highlights()
  end,
})

vim.api.nvim_create_user_command("VoyagerOpen", function()
  Voyager.open()
end, { nargs = 0 })

vim.api.nvim_create_user_command("VoyagerFocus", function()
  Voyager.focus()
end, { nargs = 0 })

vim.api.nvim_create_user_command("VoyagerSave", function()
  Voyager.save()
end, { nargs = 0 })

vim.api.nvim_create_user_command("VoyagerLoad", function()
  Voyager.load()
end, { nargs = 0 })

vim.api.nvim_create_user_command("VoyagerClose", function()
  Voyager.close()
end, { nargs = 0 })

vim.api.nvim_create_user_command("VoyagerToggle", function()
  Voyager.toggle()
end, { nargs = 0 })

vim.api.nvim_create_user_command("VoyagerExport", function()
  Voyager.export()
end, { nargs = 0 })
