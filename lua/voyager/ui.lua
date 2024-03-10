local Layout = require("nui.layout")
local Popup = require("nui.popup")
local NuiTree = require("nui.tree")
local NuiLine = require("nui.line")

---Table for layout components
local layout_components = {}

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

local function close_and_cleanup()
  layout:unmount()
  layout = nil
  layout_components = {}
end

---Initialize layout popups if not initialized yet
local function init_layout_components()
  local currbuf = vim.api.nvim_get_current_buf()

  if not layout_components.workspace then
    layout_components.workspace = Popup({
      border = get_border_config("rounded", " Workspace ", "left"),
      buf_options = get_buf_options(true, false),
      win_options = get_win_options(0, "Normal:Normal,FloatBorder:FloatBorder", true),
      enter = true,
      focusable = true,
      zindex = 50,
      bufnr = currbuf,
    })
    layout_components.workspace:map("n", "q", function()
      close_and_cleanup()
    end, { noremap = true })
    layout_components.workspace:map("n", "<ESC>", function()
      close_and_cleanup()
    end, { noremap = true })
  end

  if not layout_components.root then
    layout_components.root = Popup({
      border = get_border_config("rounded", " Root ", "left"),
      buf_options = get_buf_options(false, true),
      win_options = get_win_options(0, "Normal:Normal,FloatBorder:FloatBorder", false),
      enter = false,
      focusable = false,
      zindex = 50,
    })
    local line = NuiLine()
    local root_filename = vim.api.nvim_buf_get_name(currbuf)
    root_filename = "  " .. string.gsub(root_filename, vim.fn.getcwd(), "")
    line:append(root_filename)
    line:render(layout_components.root.bufnr, layout_components.root.ns_id, 1)
  end

  if not layout_components.outline then
    layout_components.outline = Popup({
      border = get_border_config("rounded", " Outline ", "left"),
      buf_options = get_buf_options(false, true),
      win_options = get_win_options(0, "Normal:Normal,FloatBorder:FloatBorder", false),
      enter = false,
      focusable = true,
      zindex = 50,
    })

    layout_components.outline:map("n", "q", function()
      close_and_cleanup()
    end, { noremap = true })
    layout_components.outline:map("n", "<ESC>", function()
      close_and_cleanup()
    end, { noremap = true })

    local outline_bufnr = layout_components.outline.bufnr

    local tree = NuiTree({
      bufnr = outline_bufnr,
      nodes = {
        NuiTree.Node({ text = "a" }),
        NuiTree.Node({ text = "b" }, {
          NuiTree.Node({ text = "b-1" }),
          NuiTree.Node({ text = { "b-2", "b-3" } }),
        }),
      },
    })

    tree:render()
  end
end

local function set_root_filename()
  -- TODO: set filename ofcurrent buffer in root popup
end

---@class UiModule
---Draws and manages workspace and outline
local M = {}

M.open_voyager = function()
  init_layout_components()
  local workspace_box = Layout.Box(layout_components.workspace, { size = "70%" })
  local root_box = Layout.Box(layout_components.root, { size = "10%" })
  local outline_box = Layout.Box(layout_components.outline, { size = "90%" })

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
      }, { dir = "col", size = "30%" }),
    }, { dir = "row" })
  )

  layout:mount()
end

---Unmound layout and cleanup resources
M.close_voyager = function()
  close_and_cleanup()
end

M.open_location_in_workspace = function(bufnr)
  vim.api.nvim_set_current_buf(bufnr)
end

M.push_outline_item = function(item)
  -- TODO: Push item to outline and decide what to do. If item contains one location then open it in workspace, otherwise move cursor to outine for user to select
end

M.pop_last_outline_item = function()
  -- TODO: Pop last item from outline and update workspace
end

return M
