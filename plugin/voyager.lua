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

vim.api.nvim_create_user_command("VoyagerBuild", function(args)
  local direction = args.fargs[1]
  local depth = args.fargs[2] and tonumber(args.fargs[2]) or nil
  if #args.fargs > 2 or (args.fargs[2] and depth == nil) then
    vim.notify("Voyager: usage: VoyagerBuild [callers|callees] [depth]", vim.log.levels.ERROR)
    return
  end
  Voyager.build({ direction = direction, depth = depth })
end, {
  nargs = "*",
  complete = function(arg_lead, command_line)
    local arguments = vim.split(command_line, "%s+", { trimempty = true })
    if #arguments == 1 or (#arguments == 2 and arg_lead ~= "") then
      return vim.tbl_filter(function(value)
        return vim.startswith(value, arg_lead)
      end, { "callers", "callees" })
    end
    return {}
  end,
})

vim.api.nvim_create_user_command("VoyagerBuildCancel", function()
  Voyager.cancel_build()
end, { nargs = 0 })
