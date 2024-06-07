---@class UiUtils
---Utils for UI related stuff
local UiUtils = {}

UiUtils.unlock_buffer = function(bufnr)
  vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
  vim.api.nvim_set_option_value("readonly", false, { buf = bufnr })
end

UiUtils.lock_buffer = function(bufnr)
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  vim.api.nvim_set_option_value("readonly", true, { buf = bufnr })
end

UiUtils.get_border_config = function(style, top_text, top_align)
  return {
    style = style,
    text = {
      top = top_text,
      top_align = top_align,
    },
  }
end

UiUtils.get_buf_options = function(modifiable, readonly)
  return {
    modifiable = modifiable,
    readonly = readonly,
  }
end

UiUtils.get_win_options = function(winblend, winhighlight, number, relativenumber)
  return {
    winblend = winblend,
    winhighlight = winhighlight,
    number = number,
    relativenumber = relativenumber
  }
end

return UiUtils
