local Voyager = require("voyager")

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
