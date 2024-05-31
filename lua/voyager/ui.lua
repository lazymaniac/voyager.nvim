---External dependencies
local NuiLayout = require("nui.layout")
local NuiPopup = require("nui.popup")
local NuiTree = require("nui.tree")
local NuiLine = require("nui.line")

---Internal dependencies
local VoyagerLsp = require("voyager.lsp")
local VoyagerKeymaps = require("voyager.keymaps")

---Reference to nui Layout object
local voyager_layout = {}

---Table for layout components
local layout_components = {}

local function get_border_config(style, top_text, top_align)
  return {
    style = style,
    text = {
      top = top_text,
      top_align = top_align,
    },
  }
end

local function get_buf_options(modifiable, readonly)
  return {
    modifiable = modifiable,
    readonly = readonly,
  }
end

local function get_win_options(winblend, winhighlight, number)
  return {
    winblend = winblend,
    winhighlight = winhighlight,
    number = number,
  }
end

---Close layout, free up resources, and restore global mappings
local function close_and_cleanup()
  if voyager_layout then
    voyager_layout:unmount()
    voyager_layout = nil
    layout_components = {}
    VoyagerKeymaps.restore_global_keymaps()
  end
end

local function set_close_keyamps(bufnr)
  -- stylua: ignore
  vim.keymap.set("n", "q", function() close_and_cleanup() end, { buffer = bufnr })
  -- stylua: ignore
  vim.keymap.set("n", "<ECS>", function() close_and_cleanup() end, { buffer = bufnr })
end

local function setup_close_event(nui_popup)
  local event = require("nui.utils.autocmd").event
  nui_popup:on({ event.WinClosed }, function()
    close_and_cleanup()
  end, { once = true })
end

local function set_workspace_popup_keymaps(bufnr)
  set_close_keyamps(bufnr)

  local supported_lsp_actions = VoyagerLsp.get_lsp_actions()
  for _, action in ipairs(supported_lsp_actions) do
    local handle_function = function()
      VoyagerLsp["get_" .. action](function(locations)
        vim.print(locations) -- FIXME: placeholder for specific handlers
      end)
    end
    local keymap = VoyagerKeymaps.get_local_keymap(action)
    -- stylua: ignore
    vim.keymap.set( "n", keymap.lhs, handle_function, { buffer = bufnr, noremap = true, silent = true, desc = keymap.desc })
  end
end

local function set_line_highlight(bufnr, ns_id, lnum, hl_group)
  local buf = vim.api.nvim_get_current_buf()
  if bufnr ~= buf and bufnr ~= -1 then
    return vim.notify("Buffer does not exist.")
  end

  -- Clear any existing highlighting on the line to avoid duplicates.
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, lnum, lnum)
  vim.api.nvim_buf_add_highlight(bufnr, ns_id, hl_group, lnum, 0, -1)
end


-- Define a local function to create a new highlight group
local function create_voyager_namespace()
    vim.api.nvim_create_namespace('Voyager')
end


local function set_outline_popup_keymaps(bufnr)
  set_close_keyamps(bufnr)

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
    local root_filename = vim.api.nvim_buf_get_name(currbuf)
    root_filename = "  " .. string.gsub(root_filename, vim.fn.getcwd(), "")

    layout_components.workspace = NuiPopup({
      border = get_border_config("rounded", "   :" .. root_filename, "left"),
      buf_options = get_buf_options(true, false),
      win_options = get_win_options(0, "Normal:Normal,FloatBorder:FloatBorder", true),
      enter = true,
      focusable = true,
      zindex = 50,
      bufnr = currbuf,
    })

    setup_close_event(layout_components.workspace)

    set_workspace_popup_keymaps(currbuf)
  end
end

---Create popup for outline
local function init_outline_popup(currbuf)
  if not layout_components.outline then
    layout_components.outline = NuiPopup({
      border = get_border_config("rounded", " 󰙮  Outline ", "center"),
      buf_options = get_buf_options(false, true),
      win_options = get_win_options(0, "Normal:Normal,FloatBorder:FloatBorder", false),
      enter = false,
      focusable = true,
      zindex = 50,
    })

    setup_close_event(layout_components.outline)

    set_outline_popup_keymaps(layout_components.outline.bufnr)

    local root_filename = vim.api.nvim_buf_get_name(currbuf)
    root_filename = string.gsub(root_filename, vim.fn.getcwd(), "")

    local tree = NuiTree({
      bufnr = layout_components.outline.bufnr,
      nodes = {
        NuiTree.Node({ text = "ROOT: " .. root_filename }, {}),
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
  init_outline_popup(currbuf)
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

  voyager_layout = NuiLayout(
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

  voyager_layout:mount()
end

---Unmound layout and cleanup resources
VoyagerUI.close_voyager = function()
  close_and_cleanup()
end

VoyagerUI.open_location_in_workspace = function(bufnr)
  vim.api.nvim_set_current_buf(bufnr)
end

return VoyagerUI
