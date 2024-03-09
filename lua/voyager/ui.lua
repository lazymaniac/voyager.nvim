local Layout = require("nui.layout")
local Popup = require("nui.popup")

---Table for layout popups
local layout_popups = {}

---Reference to nui Layout object
local layout = {}

---Build dict with nui border config
---@param style string one of border styles
---@param top_text string text displayed on top border
---@param top_align string text alignment on top border
---@return table table border configuration for nui popup
local function get_border_config(style, top_text, top_align)
  return {
    style = style,
    text = {
      top = top_text,
      top_align = top_align,
    },
  }
end

---Build table with nui buffer options
---@param modifiable boolean
---@param readonly boolean
---@return table
local function get_buf_options(modifiable, readonly)
  return {
    modifiable = modifiable,
    readonly = readonly,
  }
end

---Build table with nui window options
---@param winblend integer
---@param winhighlight string
---@param number boolean
---@return table
local function get_win_options(winblend, winhighlight, number)
  return {
    winblend = winblend,
    winhighlight = winhighlight,
    number = number,
  }
end

---Initialize layout popups if not initialized yet
local function init_popups()
  if not layout_popups.workspace then
    local currbuf = vim.api.nvim_get_current_buf()
    layout_popups.workspace = Popup({
      border = get_border_config("rounded", " Workspace ", "left"),
      buf_options = get_buf_options(true, false),
      win_options = get_win_options(0, "Normal:Normal,FloatBorder:FloatBorder", true),
      enter = true,
      focusable = true,
      zindex = 50,
      bufnr = currbuf,
    })
  end

  if not layout_popups.root then
    layout_popups.root = Popup({
      border = get_border_config("rounded", " Root ", "left"),
      buf_options = get_buf_options(false, true),
      win_options = get_win_options(0, "Normal:Normal,FloatBorder:FloatBorder", false),
      enter = false,
      focusable = false,
      zindex = 50,
    })
  end

  if not layout_popups.outline then
    layout_popups.outline = Popup({
      border = get_border_config("rounded", " Outline ", "left"),
      buf_options = get_buf_options(false, true),
      win_options = get_win_options(0, "Normal:Normal,FloatBorder:FloatBorder", false),
      enter = false,
      focusable = true,
      zindex = 50,
    })
  end
end

---@class UiModule
---Draws and manages workspace and outline
local M = {}

M.open_voyager = function()
  init_popups()
  local workspace_box = Layout.Box(layout_popups.workspace, { size = "80%" })
  local root_box = Layout.Box(layout_popups.root, { size = "10%" })
  local outline_box = Layout.Box(layout_popups.outline, { size = "90%" })

  layout = Layout(
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
      Layout.Box({
        root_box,
        outline_box,
      }, { dir = "col", size = "20%" }),
    }, { dir = "row" })
  )

  layout:mount()
end

---Unmound layout and cleanup resources
M.close_voyager = function ()
  layout:unmount()
  layout = nil
  layout_popups = {}
end

M.open_location_in_workspace = function(bufnr)
  vim.api.nvim_set_current_buf(bufnr)
end

M.push_outline_item = function(item)
  -- TODO: Push item to outline and decide what to do. If item contains one location then open it in workspace, otherwise move cursor to outine for user to select
end

M.pop_last_outline_item = function ()
  -- TODO: Pop last item from outline and update workspace
end

return M
