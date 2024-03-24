local Layout = require("nui.layout")
local Popup = require("nui.popup")
local NuiTree = require("nui.tree")
local NuiLine = require("nui.line")
local lsp = require("voyager.lsp")

---Table for layout components
local layout_components = {}

---Reference to nui Layout object
local layout = {}

local function get_existing_mapping(mode, lhs)
end

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

---Close layout and free resources
local function close_and_cleanup()
  vim.keymap.del("n", "q", { buffer = layout_components.workspace.bufnr })
  vim.keymap.del("n", "<ESC>", { buffer = layout_components.workspace.bufnr })
  vim.keymap.del("n", "gd", { buffer = layout_components.workspace.bufnr })
  layout:unmount()
  layout = nil
  layout_components = {}
end

---Create popups used to construct layout. Apply settings and keymaps
---@param currbuf integer current buf number used as starting point
local function init_workspace_popup(currbuf)
  if not layout_components.workspace then
    layout_components.workspace = Popup({
      border = get_border_config("rounded", "   Workspace: ", "left"),
      buf_options = get_buf_options(true, false),
      win_options = get_win_options(0, "Normal:Normal,FloatBorder:FloatBorder", true),
      enter = true,
      focusable = true,
      zindex = 50,
      bufnr = currbuf,
    })
    vim.keymap.set("n", "q", function()
      close_and_cleanup()
    end, { buffer = currbuf })
    vim.keymap.set("n", "<ECS>", function()
      close_and_cleanup()
    end, { buffer = currbuf })
    vim.keymap.set("n", "gd", function()
      lsp.get_definition(function(locations)
        -- TODO: handle definition
        --
        -- NOTE: Code snippet how to handle conversion for location to item and go to location
        --[[ for client_id, result in pairs(locations) do
          vim.print(result)
          local client = assert(vim.lsp.get_client_by_id(client_id))
          local items = vim.lsp.util.locations_to_items(result.result, client.offset_encoding)
          print("item", items[1].text)
          vim.lsp.util.jump_to_location(result.result[1], client.offset_encoding, false)
        end ]]
        vim.print(locations)
      end)
    end, { buffer = currbuf, desc = "VGoto Definition" })
    layout_components.workspace:map("n", "gr", function()
      lsp.get_references(function(locations)
        -- TODO: handle references
        vim.print(locations)
      end)
    end, { noremap = true })
    layout_components.workspace:map("n", "gI", function()
      lsp.get_implementations(function(locations)
        -- TODO: handle implementations
        vim.print(locations)
      end)
    end, { noremap = true })
    layout_components.workspace:map("n", "gD", function()
      lsp.get_type_definition(function(locations)
        -- TODO: handle type definition
        vim.print(locations)
      end)
    end, { noremap = true })
    layout_components.workspace:map("n", "gC", function()
      lsp.get_incoming_calls(function(locations)
        -- TODO: handle incoming calls
        vim.print(locations)
      end)
    end, { noremap = true })
    layout_components.workspace:map("n", "gG", function()
      lsp.get_outgoing_calls(function(locations)
        -- TODO: handle outgoing calls
        vim.print(locations)
      end)
    end, { noremap = true })
  end
end

---Create popup for start point
---@param currbuf integer current buffer identifier
local function init_root_popup(currbuf)
  if not layout_components.root then
    layout_components.root = Popup({
      border = get_border_config("rounded", " 󰑃  Start point ", "left"),
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
end

---Create popup for outline
local function init_outline_popup()
  if not layout_components.outline then
    layout_components.outline = Popup({
      border = get_border_config("rounded", " 󰙮  Outline ", "left"),
      buf_options = get_buf_options(false, true),
      win_options = get_win_options(0, "Normal:Normal,FloatBorder:FloatBorder", false),
      enter = false,
      focusable = true,
      zindex = 50,
    })

    layout_components.outline:map("n", "q", function()
      close_and_cleanup()
    end, { noremap = true, desc = "Quit Voyager" })
    layout_components.outline:map("n", "<ESC>", function()
      close_and_cleanup()
    end, { noremap = true, desc = "Quit Voyager" })
    layout_components.outline:map("n", "o", function()
      vim.print(vim.api.nvim_get_current_line())
      vim.api.nvim_set_current_win(layout_components.workspace.winid)
    end, { noremap = true, desc = "Open Item in Workspace" })

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
  init_root_popup(currbuf)
  init_outline_popup()
end

---@class UiModule
---Draws and manages workspace and outline
local M = {}

---Open Voyager layout and init all resources
M.open_voyager = function()
  init_layout_components()
  local workspace_box = Layout.Box(layout_components.workspace, { size = "70%" })
  local root_box = Layout.Box(layout_components.root, { size = 3 })
  local outline_box = Layout.Box(layout_components.outline, { size = vim.api.nvim_win_get_height(0) - 4 })

  layout = Layout(
    {
      position = "50%",
      border = "none",
      size = {
        width = vim.api.nvim_win_get_width(0) - 2,
        height = vim.api.nvim_win_get_height(0) - 1,
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

return M
