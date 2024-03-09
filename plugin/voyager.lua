vim.api.nvim_create_user_command("VRef", require("voyager").get_references, {})
vim.api.nvim_create_user_command("Voyager", require("voyager").open_vyager, {})
