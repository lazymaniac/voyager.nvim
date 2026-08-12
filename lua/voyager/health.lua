local M = {}

function M.check()
  local health = vim.health
  health.start("voyager.nvim")

  if vim.fn.has("nvim-0.12.4") == 1 then
    health.ok("Neovim " .. tostring(vim.version()) .. " meets the 0.12.4 target")
  else
    health.error("Neovim 0.12.4 or newer is required", "Update Neovim")
  end

  local nui_ok = pcall(require, "nui.popup")
  if nui_ok then
    health.ok("nui.nvim is available")
  else
    health.error("nui.nvim is not installed", "Install MunifTanjim/nui.nvim")
  end

  if pcall(vim.api.nvim_get_autocmds, { event = "LspRequest" }) then
    health.ok("LspRequest autocmd is available for passive recording")
  else
    health.error("LspRequest autocmd is unavailable; navigation cannot be observed")
  end

  local cwd = vim.fn.getcwd()
  if vim.uv.fs_access(cwd, "W") then
    health.ok("current directory is writable for .voyager/flows storage: " .. cwd)
  else
    health.warn(
      "current directory is not writable: " .. cwd,
      "Saved flows are written to <project-root>/.voyager/flows"
    )
  end

  health.info("The default sidebar icons use Nerd Font glyphs; set sidebar.icons = false for plain text")
end

return M
