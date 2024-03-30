---External dependencies
local NuiLayout = require("nui.layout")
local NuiPopup = require("nui.popup")
local NuiTree = require("nui.tree")
local NuiLine = require("nui.line")

---Internal dependencies
local VoyagerLsp = require("voyager.lsp")
local VoyagerKeymaps = require("voyager.keymaps")

---Reference to nui Layout object
local layout = {}

---Table for layout components
local layout_components = {}

---Returns tables with nui border config
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

---Returns table with nui buffer options
---@param modifiable boolean is buffer modifiable
---@param readonly boolean is buffer readonly
---@return table buffer configuration for nui popup
local function get_buf_options(modifiable, readonly)
  return {
    modifiable = modifiable,
    readonly = readonly,
  }
end

---Returns table with nui window options
---@param winblend integer set window blend
---@param winhighlight string alter highlights
---@param number boolean show line nubers
---@return table window options for nui popup
local function get_win_options(winblend, winhighlight, number)
  return {
    winblend = winblend,
    winhighlight = winhighlight,
    number = number,
  }
end

---Close layout, free up resources, and restore global mappings
local function close_and_cleanup()
  if layout then
    layout:unmount()
    layout = nil
    layout_components = {}
    VoyagerKeymaps.restore_global_keymaps()
  end
end

local function set_workspace_popup_keymaps(currbuf)
  -- stylua: ignore
  vim.keymap.set("n", "q", function() close_and_cleanup() end, { buffer = currbuf })
  -- stylua: ignore
  vim.keymap.set("n", "<ECS>", function() close_and_cleanup() end, { buffer = currbuf })

  local supported_lsp_actions = VoyagerLsp.get_lsp_actions()
  for _, action in ipairs(supported_lsp_actions) do
    local handle_function = function()
      VoyagerLsp["get_" .. action](function(locations)
        vim.print(locations) -- FIXME: placeholder for specific handlers
      end)
    end
    local keymap = VoyagerKeymaps.get_local_keymap(action)
    -- stylua: ignore
    vim.keymap.set( "n", keymap.lhs, handle_function, { buffer = currbuf, noremap = true, silent = true, desc = keymap.desc })
  end
end

local function set_outline_popup_keymaps(bufnr)
  -- stylua: ignore
  vim.keymap.set("n", "q", function() close_and_cleanup() end, { buffer = bufnr, noremap = true, silent = true, desc = "Quit Voyager" })
  -- stylua: ignore
  vim.keymap.set("n", "<ESC>", function() close_and_cleanup() end, { buffer = bufnr, noremap = true, silent = true, desc = "Quit Voyager" })

  -- Set additional outline-specific bindings
  local navigation_handler = function()
    vim.print(vim.api.nvim_get_current_line())
    vim.api.nvim_set_current_win(layout_components.workspace.winid)
  end

  -- stylua: ignore
  vim.keymap.set( "n", "o", navigation_handler, { buffer = bufnr, noremap = true, silent = true, desc = "Open Item in Workspace" })
  -- stylua: ignore
  vim.keymap.set( "n", "<CR>", navigation_handler, { buffer = bufnr, noremap = true, silent = true, desc = "Open Item in Workspace" })
end

---Create popups used to construct layout. Apply settings and keymaps
---@param currbuf integer current buf number used as starting point
local function init_workspace_popup(currbuf)
  if not layout_components.workspace then
    layout_components.workspace = NuiPopup({
      border = get_border_config("rounded", "   Workspace: ", "left"),
      buf_options = get_buf_options(true, false),
      win_options = get_win_options(0, "Normal:Normal,FloatBorder:FloatBorder", true),
      enter = true,
      focusable = true,
      zindex = 50,
      bufnr = currbuf,
    })

    local event = require("nui.utils.autocmd").event
    layout_components.workspace:on({ event.WinClosed }, function()
      close_and_cleanup()
    end, { once = true })

    set_workspace_popup_keymaps(currbuf)
  end
end

---Create popup for outline
local function init_outline_popup()
  if not layout_components.outline then
    layout_components.outline = NuiPopup({
      border = get_border_config("rounded", " 󰙮  Outline ", "left"),
      buf_options = get_buf_options(false, true),
      win_options = get_win_options(0, "Normal:Normal,FloatBorder:FloatBorder", false),
      enter = false,
      focusable = true,
      zindex = 50,
    })
    local event = require("nui.utils.autocmd").event

    layout_components.outline:on({ event.WinClosed }, function()
      close_and_cleanup()
    end, { once = true })

    set_outline_popup_keymaps(layout_components.outline.bufnr)

    local outline_bufnr = layout_components.outline.bufnr

    local tree = NuiTree({
      bufnr = outline_bufnr,
      nodes = {
        NuiTree.Node({ text = "Root " }, {}),
        NuiTree.Node({ text = "b" }, {
          NuiTree.Node({ text = "b-1" }),
          NuiTree.Node({ text = { "b-2", "b-3" } }),
        }),
      },
    })

    tree:render()
  end
end

---Initialize all layout popups if not initialized yet
local function init_layout_components()
  local currbuf = vim.api.nvim_get_current_buf()

  init_workspace_popup(currbuf)
  init_outline_popup()
end

---@class VoyagerUI
---Draws and manages workspace and outline
local VoyagerUI = {}

---Open Voyager layout and init all resources
---@param user_config table user configuration
VoyagerUI.open_voyager = function(user_config)
  VoyagerKeymaps.set_keymaps_from_config(user_config.keymaps)

  VoyagerKeymaps.find_conflicting_global_keymaps()

  init_layout_components()

  local workspace_box = NuiLayout.Box(layout_components.workspace, { size = "75%" })
  local outline_box = NuiLayout.Box(layout_components.outline, { size = "25%" })

  layout = NuiLayout(
    {
      position = "50%",
      border = "none",
      size = {
        width = vim.api.nvim_win_get_width(0) - 2,
        height = vim.api.nvim_win_get_height(0) - 1,
      },
    },
    NuiLayout.Box({
      workspace_box,
      outline_box,
    }, { dir = "row" })
  )

  layout:mount()
end

---Unmound layout and cleanup resources
VoyagerUI.close_voyager = function()
  close_and_cleanup()
end

VoyagerUI.open_location_in_workspace = function(bufnr)
  vim.api.nvim_set_current_buf(bufnr)
end

return VoyagerUI
