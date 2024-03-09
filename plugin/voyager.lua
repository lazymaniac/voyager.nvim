vim.api.nvim_create_user_command("VRef", require("voyager").get_references, {})
vim.api.nvim_create_user_command("VoyagerOpen", require("voyager").open_voyager, {})
vim.api.nvim_create_user_command("VoyagerClose", require("voyager").close_voyager, {})
