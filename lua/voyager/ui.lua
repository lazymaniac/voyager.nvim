---External dependencies
local NuiLayout = require("nui.layout")
local NuiPopup = require("nui.popup")
local NuiLine = require("nui.line")
local NuiText = require("nui.text")

---Internal dependencies
local LspClient = require("voyager.lsp_client")
local Keymaps = require("voyager.keymaps")
local LocationsStack = require("voyager.locations_stack")
local LspUtils = require("voyager.utils.lsp_utils")
local UiUtils = require("voyager.utils.ui_utils")
local LuaUtils = require("voyager.utils.lua_utils")

---Reference to nui Layout object
local layout = {}

---Table for layout components
local layout_components = {}

---Holds current state of outline
local line_to_location = {}

local icons = {
  current = "  ",
  outline = " 󰯓 ",
  root = " 󰾕 ",
  selected = " 󱔲 ",
  select = " 󰾙 ",
}

---Close layout, free up resources, and restore global mappings
local function close_and_cleanup()
  if layout then
    layout:unmount()
    layout = nil
    layout_components = {}
    Keymaps.restore_global_keymaps()
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

local function focus_outline()
  vim.api.nvim_set_current_win(layout_components.outline.winid)
end

local function build_outline_content()
  local locations = LocationsStack.get_all()
  for index, lsp_result in ipairs(locations) do
    local method = LspUtils.pretty_lsp_method(lsp_result.method)
    local origin_text = string.format(
      " %d. %s: [%s] @ %s:%d",
      index,
      method,
      lsp_result.parent.cword_symbol,
      lsp_result.parent.cfile,
      lsp_result.parent.line_num + 1
    )

    line_to_location[origin_text] = {
      line = NuiLine({
        NuiText(origin_text, "@attribute"),
      }),
      location = nil,
    }

    for _, lsp_client in pairs(lsp_result.locations) do
      for i, location in ipairs(lsp_client.result) do
        local uri = location.targetUri or location.uri
        if not uri then
          return
        end

        local buf = vim.uri_to_bufnr(uri)
        if not vim.api.nvim_buf_is_loaded(buf) then
          vim.fn.bufload(buf)
        end
        local range = location.targetRange or location.range
        -- local contents = vim.api.nvim_buf_get_lines(buf, range.start.line, range["end"].line + 1, false)

        local location_text = string.format(
          " %d.%d. %s:%d",
          index,
          i,
          uri:gsub("^%s", ""):gsub(vim.fn.getcwd(), ""):gsub("file://", ""),
          range.start.line + 1
        )

        line_to_location[location_text] = {
          line = NuiLine({
            NuiText(location_text),
          }),
          location = location,
        }
      end
    end
  end
end

local function render_outline_content()
  local outline_bufnr = layout_components.outline.bufnr
  UiUtils.unlock_buffer(outline_bufnr)
  local i = 1
  for _, k in ipairs(LuaUtils.table_sort_keys(line_to_location)) do
    line_to_location[k].line:render(outline_bufnr, -1, i)
    i = i + 1
  end
  UiUtils.lock_buffer(outline_bufnr)
  if i > 1 then
    focus_outline()
  end
end

local function redraw_outline()
  build_outline_content()
  render_outline_content()
end

local function set_workspace_popup_keymaps(bufnr)
  set_close_keyamps(bufnr)

  -- Set keymaps for each lsp actions
  local supported_lsp_actions = LspClient.get_lsp_actions()
  for _, action in ipairs(supported_lsp_actions) do
    local handle_function = function()
      LspClient["get_" .. action](function()
        redraw_outline()
      end)
    end
    local keymap = Keymaps.get_local_keymap(action)
    -- stylua: ignore
    vim.keymap.set( "n", keymap.lhs, handle_function, { buffer = bufnr, noremap = true, silent = true, desc = keymap.desc })
  end
end

local function set_outline_popup_keymaps(bufnr)
  set_close_keyamps(bufnr)

  local navigation_handler = function()
    local line_position = vim.api.nvim_win_get_cursor(layout_components.outline.winid)
    local selected_line =
      vim.api.nvim_buf_get_lines(layout_components.outline.bufnr, line_position[1] - 1, line_position[1], true)[1]
    local location = line_to_location[selected_line].location
    if not location then
      return
    end
    local uri = location.uri or location.targetUri
    if not uri then
      return
    end
    local dest_bufnr = vim.uri_to_bufnr(uri)
    vim.api.nvim_win_set_buf(layout_components.workspace.winid, dest_bufnr)
    local range = location.range or location.targetSelectionRange
    if range then
      vim.api.nvim_set_current_win(layout_components.workspace.winid)
      vim.api.nvim_win_set_cursor(layout_components.workspace.winid, { range.start.line + 1, range.start.character })
      vim.api.nvim_win_call(layout_components.outline.winid, function()
        -- Open folds under the cursor
        vim.cmd("normal! zv")
      end)
    end
  end

  -- stylua: ignore
  vim.keymap.set( "n", "o", navigation_handler, { buffer = bufnr, noremap = true, silent = true, desc = "Open Item in Workspace" })
  -- stylua: ignore
  vim.keymap.set( "n", "<CR>", navigation_handler, { buffer = bufnr, noremap = true, silent = true, desc = "Open Item in Workspace" })

  -- TODO: add keymaps to manage outline items like removing last added locations and selecting other parent or saving current stack locations.
end

---Create popups used to construct layout. Apply settings and keymaps
---@param currbuf integer current buf number used as starting point
local function init_workspace_popup(currbuf)
  if not layout_components.workspace then
    local root_filename = vim.api.nvim_buf_get_name(currbuf)
    root_filename = " .." .. string.gsub(root_filename, vim.fn.getcwd(), "")

    layout_components.workspace = NuiPopup({
      border = UiUtils.get_border_config("rounded", icons.current .. " :" .. root_filename, "center"),
      buf_options = UiUtils.get_buf_options(true, false),
      win_options = UiUtils.get_win_options(
        0,
        "Normal:Normal,FloatBorder:FloatBorder",
        vim.o.number,
        vim.o.relativenumber
      ),
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
      border = UiUtils.get_border_config("rounded", icons.outline .. " Outline ", "center"),
      buf_options = UiUtils.get_buf_options(false, true),
      win_options = UiUtils.get_win_options(0, "Normal:Normal,FloatBorder:FloatBorder", false),
      enter = false,
      focusable = true,
      zindex = 50,
    })

    setup_close_event(layout_components.outline)

    set_outline_popup_keymaps(layout_components.outline.bufnr)
  end
end

---Initialize all layout popups if not initialized yet
local function init_layout_components()
  local currbuf = vim.api.nvim_get_current_buf()

  init_workspace_popup(currbuf)
  init_outline_popup(currbuf)
end

---@class UI
---Draws and manages workspace and outline
local UI = {}

---Open Voyager layout and init all resources
---@param user_config table user configuration
UI.open_voyager = function(user_config)
  Keymaps.set_keymaps_from_config(user_config.keymaps)

  Keymaps.find_conflicting_global_keymaps()

  init_layout_components()

  local workspace_box = NuiLayout.Box(layout_components.workspace, { size = "75%" })
  local outline_box = NuiLayout.Box(layout_components.outline, { size = "25%" })

  layout = NuiLayout(
    {
      position = "50%",
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
  redraw_outline()
end

---Unmound layout and cleanup resources
UI.close_voyager = function()
  close_and_cleanup()
end

UI.open_location_in_workspace = function(bufnr)
  vim.api.nvim_set_current_buf(bufnr)
end

return UI
