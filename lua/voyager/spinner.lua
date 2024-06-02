---@class Spinner Utility class for spinner handling
local Spinner = {}

-- Utility consts to manage spinner display
-- stylua: ignore
local spinner_states = { " 󱑖  ", " 󱑋  ", " 󱑌  ", " 󱑍  ", " 󱑎  ", " 󱑏  ", " 󱑐  ", " 󱑑  ", " 󱑒  ", " 󱑓  ", " 󱑔  ", " 󱑕  ", }
local spinner_index = 1
local spinner_buf = nil
local spinner_win = nil

-- Function to show spinner
Spinner.start = function()
  if not spinner_buf then
    spinner_buf = vim.api.nvim_create_buf(false, true)
    spinner_win = vim.api.nvim_open_win(spinner_buf, false, {
      relative = "cursor",
      row = 0,
      col = 0,
      width = 13,
      height = 1,
      style = "minimal",
      border = "none",
      zindex = 500,
    })
  end
  -- Update spinner every 100ms
  vim.defer_fn(function()
    -- Rotate spinner
    spinner_index = (spinner_index % #spinner_states) + 1
    if spinner_buf then
      vim.api.nvim_buf_set_lines(spinner_buf, 0, -1, false, { " Loading " .. spinner_states[spinner_index] })
    end
    if spinner_buf then
      Spinner:start()
    end
  end, 100)
end

-- Function to stop spinner
Spinner.stop = function()
  if spinner_buf then
    vim.api.nvim_buf_delete(spinner_buf, { force = true })
    spinner_buf = nil
  end
  if spinner_win then
    vim.api.nvim_win_close(spinner_win, true)
  end
end

return Spinner
