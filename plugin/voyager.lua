vim.api.nvim_create_user_command("MyFirstFunction", require("lua.voyager").hello, {})
