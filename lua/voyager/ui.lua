local Layout = require("nui.layout")
local Popup = require("nui.popup")

local workspace_popup
local outline_popup

---@class UiModule
---Draws and manages workspace and outline
local M = {}

M.build_layout = function()
  local currbuf = vim.api.nvim_get_current_buf()
  workspace_popup = Popup({
    border = {
      style = "rounded",
      text = {
        top = " Workspace ",
        top_align = "left",
      },
    },
    buf_options = {
      modifiable = true,
      readonly = false,
    },
    win_options = {
      winblend = 0,
      winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
    },
    enter = true,
    focusable = true,
    zindex = 50,
    bufnr = currbuf,
  })
  outline_popup = Popup({
    border = {
      style = "rounded",
      text = {
        top = " References ",
        top_align = "left",
      },
    },
    buf_options = {
      modifiable = false,
      readonly = true,
    },
    win_options = {
      winblend = 0,
      winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
    },
    enter = false,
    focusable = true,
    zindex = 50,
  })

  local workspace_box = Layout.Box(workspace_popup, { size = "80%" })
  local outline_box = Layout.Box({
    Layout.Box(outline_popup, { size = "20%" }),
  }, { dir = "col", size = "20%" })

  local layout = Layout(
    {
      position = "50%",
      border = "none",
      size = {
        width = 0.99,
        height = 0.99,
      },
    },
    Layout.Box({
      workspace_box,
      outline_box,
    }, { dir = "row" })
  )

  layout:mount()
end

M.open_location_in_workspace = function(bufnr)
  vim.api.nvim_set_current_buf(bufnr)
end

M.push_outline_item = function(item) end

return M
