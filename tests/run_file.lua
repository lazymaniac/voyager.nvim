return function(path)
  local ok, err = xpcall(function()
    require("plenary.busted").run(path)
  end, debug.traceback)
  if not ok then
    vim.api.nvim_err_writeln(err)
    vim.cmd("2cq")
  end
end
