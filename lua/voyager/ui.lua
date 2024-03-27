---External dependencies
local Layout = require("nui.layout")
local Popup = require("nui.popup")
local NuiTree = require("nui.tree")
local NuiLine = require("nui.line")

---Internal dependencies
local lsp = require("voyager.lsp")
local keymaps = require("voyager.keymaps")

---Table for layout components
local layout_components = {}

---Reference to nui Layout object
local layout = {}

---Goto actions supported by plugins
local actions = {
  definition = "def",
  references = "ref",
  type_definition = "type_def",
  implementation = "impl",
  incoming_calls = "inc",
  outgoing_calls = "out",
}

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
  layout:unmount()
  layout = nil
  layout_components = {}
  keymaps.restore_global_keymaps()
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

    vim.keymap.set("n", keymaps.get_local_mapping(actions["definition"]), function()
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
    end, { buffer = currbuf, noremap = true, silent = true, desc = "VGoto Definition" })

    vim.keymap.set("n", keymaps.get_local_mapping(actions["references"]), function()
      lsp.get_references(function(locations)
        -- TODO: handle references
        vim.print(locations)
      end)
    end, { buffer = currbuf, noremap = true, silent = true, desc = "VGoto References" })

    vim.keymap.set("n", keymaps.get_local_mapping(actions["implementation"]), function()
      lsp.get_implementations(function(locations)
        -- TODO: handle implementations
        vim.print(locations)
      end)
    end, { buffer = currbuf, noremap = true, silent = true, desc = "VGoto Implementation" })

    vim.keymap.set("n", keymaps.get_local_mapping(actions["type_definition"]), function()
      lsp.get_type_definition(function(locations)
        -- TODO: handle type definition
        vim.print(locations)
      end)
    end, { buffer = currbuf, noremap = true, silent = true, desc = "VGoto Type Definition" })

    vim.keymap.set("n", keymaps.get_local_mapping(actions["incoming_calls"]), function()
      lsp.get_incoming_calls(function(locations)
        -- TODO: handle incoming calls
        vim.print(locations)
      end)
    end, { buffer = currbuf, noremap = true, silent = true, desc = "VIncoming Calls" })

    vim.keymap.set("n", keymaps.get_local_mapping(actions["outgoing_calls"]), function()
      lsp.get_outgoing_calls(function(locations)
        -- TODO: handle outgoing calls
        vim.print(locations)
      end)
    end, { buffer = currbuf, noremap = true, silent = true, desc = "VOutgoing Calls" })
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

    vim.keymap.set("n", "q", function()
      close_and_cleanup()
    end, { buffer = layout_components.outline.bufnr, noremap = true, silent = true, desc = "Quit Voyager" })

    vim.keymap.set("n", "<ESC>", function()
      close_and_cleanup()
    end, { buffer = layout_components.outline.bufnr, noremap = true, silent = true, desc = "Quit Voyager" })

    vim.keymap.set("n", "o", function()
      vim.print(vim.api.nvim_get_current_line())
      vim.api.nvim_set_current_win(layout_components.workspace.winid)
    end, { buffer = layout_components.outline.bufnr, noremap = true, silent = true, desc = "Open Item in Workspace" })

    vim.keymap.set("n", "<CR>", function()
      vim.print(vim.api.nvim_get_current_line())
      vim.api.nvim_set_current_win(layout_components.workspace.winid)
    end, { buffer = layout_components.outline.bufnr, noremap = true, silent = true, desc = "Open Item in Workspace" })

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
---@param user_config table user configuration
M.open_voyager = function(user_config)
  keymaps.set_keymaps(user_config.mappings)
  keymaps.find_conflicting_global_keymaps()
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
