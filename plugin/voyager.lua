vim.api.nvim_create_user_command("VoyagerOpen", require("voyager").open_voyager, {})
vim.api.nvim_create_user_command("VoyagerClose", require("voyager").close_voyager, {})
