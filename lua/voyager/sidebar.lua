local M = {}
local Sidebar = {}
Sidebar.__index = Sidebar

local function truncate(text, width)
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local ellipsis = "…"
  local target = math.max(0, width - vim.fn.strdisplaywidth(ellipsis))
  local characters = vim.fn.strchars(text)
  while characters > 0 do
    local prefix = vim.fn.strcharpart(text, 0, characters)
    if vim.fn.strdisplaywidth(prefix) <= target then
      return prefix .. ellipsis
    end
    characters = characters - 1
  end
  return ellipsis
end

local function locator_text(locator)
  return locator.path or locator.uri or "<unknown>"
end

local function contains_current(action, current_node_id)
  local function visit(location)
    if location.id == current_node_id then
      return true
    end
    for _, child in ipairs(location.actions) do
      if contains_current(child, current_node_id) then
        return true
      end
    end
    return false
  end
  for _, result in ipairs(action.results) do
    if visit(result) then
      return true
    end
  end
  return false
end

local function row(kind, owner_id, text, depth, marker, width)
  return {
    kind = kind,
    owner_id = owner_id,
    text = truncate(text, width),
    depth = depth,
    marker = marker,
  }
end

function M.project(flow, width, status)
  status = status or {}
  local rows = {}

  local visit_location
  local visit_action

  visit_location = function(node, depth)
    local marker
    local glyph = "  "
    if node.id == flow.current_node_id then
      marker = "current"
      glyph = "● "
    elseif node.stale then
      marker = "stale"
      glyph = "! "
    end
    local location = node.location
    local text = string.rep("  ", depth)
      .. glyph
      .. location.symbol
      .. " — "
      .. locator_text(location.locator)
      .. ":"
      .. (location.range.start.line + 1)
    table.insert(rows, row("location", node.id, text, depth, marker, width))
    if node.note then
      local note_depth = depth + 1
      local note_text = string.rep("  ", note_depth) .. "✎ " .. node.note
      table.insert(rows, row("note", node.id, note_text, note_depth, "note", width))
    end
    for _, action in ipairs(node.actions) do
      visit_action(action, depth + 1)
    end
  end

  visit_action = function(node, depth)
    local marker
    local current_glyph = ""
    if node.collapsed and contains_current(node, flow.current_node_id) then
      marker = "descendant_current"
      current_glyph = "● "
    end
    local disclosure = node.collapsed and "▸ " or "▾ "
    local text = string.rep("  ", depth) .. current_glyph .. disclosure .. node.label .. " (" .. #node.results .. ")"
    table.insert(rows, row("action", node.id, text, depth, marker, width))
    if not node.collapsed then
      for _, result in ipairs(node.results) do
        visit_location(result, depth + 1)
      end
    end
  end

  visit_location(flow.root, 0)
  local header = "Voyager · " .. flow.name
  if status.dirty then
    header = header .. " *"
  end
  local count = status.request_count or 0
  if count > 0 then
    header = header .. string.format(" · %d request%s", count, count == 1 and "" or "s")
  end
  return rows, truncate(header, width)
end

function M.selection_index(rows, previous_kind, previous_owner_id, hidden_by_action_id)
  for index, candidate in ipairs(rows) do
    if candidate.kind == previous_kind and candidate.owner_id == previous_owner_id then
      return index
    end
  end
  if hidden_by_action_id then
    for index, candidate in ipairs(rows) do
      if candidate.kind == "action" and candidate.owner_id == hidden_by_action_id then
        return index
      end
    end
  end
  return 1
end

function M.compute_geometry(config, ui_state)
  if ui_state.columns < 24 then
    return nil, "editor must be at least 24 columns wide"
  end

  local height = ui_state.lines - ui_state.tabline_rows - ui_state.statusline_rows - ui_state.cmdheight
  if height < 4 then
    return nil, "editor must have at least 4 usable rows"
  end

  local width = math.min(config.width, ui_state.columns - 2)
  return {
    row = ui_state.tabline_rows,
    col = config.side == "left" and 0 or ui_state.columns - width,
    width = width,
    height = height,
  }
end

local function native_ui_state()
  local tabline_rows = 0
  if vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1) then
    tabline_rows = 1
  end

  local statusline_rows = 0
  if vim.o.laststatus == 2 or vim.o.laststatus == 3 then
    statusline_rows = 1
  elseif vim.o.laststatus == 1 then
    local normal_windows = 0
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(winid).relative == "" then
        normal_windows = normal_windows + 1
      end
    end
    statusline_rows = normal_windows > 1 and 1 or 0
  end

  return {
    columns = vim.o.columns,
    lines = vim.o.lines,
    tabline_rows = tabline_rows,
    statusline_rows = statusline_rows,
    cmdheight = vim.o.cmdheight,
  }
end

local function content_size(config, geometry)
  local border_cells = config.border == "none" and 0 or 2
  return {
    width = geometry.width - border_cells,
    height = geometry.height - border_cells,
  }
end

local function popup_layout(config, geometry)
  return {
    relative = "editor",
    position = { row = geometry.row, col = geometry.col },
    size = content_size(config, geometry),
  }
end

local function popup_cursor(popup)
  if popup.get_cursor then
    return popup:get_cursor()
  end
  if popup.winid and vim.api.nvim_win_is_valid(popup.winid) then
    return vim.api.nvim_win_get_cursor(popup.winid)
  end
end

local function set_popup_cursor(popup, cursor)
  if popup.set_cursor then
    popup:set_cursor(cursor)
  elseif popup.winid and vim.api.nvim_win_is_valid(popup.winid) then
    vim.api.nvim_win_set_cursor(popup.winid, cursor)
  end
end

local function hidden_by_action(flow, owner_id)
  local function visit_location(location, hidden)
    if location.id == owner_id then
      return hidden
    end
    for _, action in ipairs(location.actions) do
      if action.id == owner_id then
        return hidden
      end
      local descendant_hidden = hidden or (action.collapsed and action.id)
      for _, result in ipairs(action.results) do
        local found = visit_location(result, descendant_hidden)
        if found then
          return found
        end
      end
    end
  end
  return visit_location(flow.root, nil)
end

local function each_lhs(value, callback)
  if value == false or value == nil then
    return
  end
  if type(value) == "table" then
    for _, lhs in ipairs(value) do
      callback(lhs)
    end
  else
    callback(value)
  end
end

function M.new(opts)
  assert(type(opts) == "table", "Voyager sidebar options are required")
  assert(type(opts.sidebar) == "table", "Voyager sidebar configuration is required")
  assert(type(opts.keymaps) == "table", "Voyager sidebar keymaps are required")
  assert(type(opts.handlers) == "table", "Voyager sidebar handlers are required")
  assert(type(opts.notify) == "function", "Voyager sidebar notification adapter is required")

  return setmetatable({
    _config = vim.deepcopy(opts.sidebar),
    _handlers = opts.handlers,
    _keymaps = vim.deepcopy(opts.keymaps),
    _line_to_row = {},
    _mounted = false,
    _notify = opts.notify,
    _popup_factory = opts.popup_factory or require("nui.popup"),
    _ui_state = opts.ui_state or native_ui_state,
  }, Sidebar)
end

function Sidebar:_clear_winclosed()
  if self._winclosed_autocmd then
    pcall(vim.api.nvim_del_autocmd, self._winclosed_autocmd)
    self._winclosed_autocmd = nil
  end
end

function Sidebar:_on_winclosed()
  self._winclosed_autocmd = nil
  self._mounted = false
  if not self._internal_close then
    self._handlers.external_close()
  end
end

function Sidebar:_bind_winclosed()
  local callback = function()
    self:_on_winclosed()
  end
  if self._popup.on_win_closed then
    self._popup:on_win_closed(callback)
  else
    self:_clear_winclosed()
    self._winclosed_autocmd = vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(self._popup.winid),
      once = true,
      callback = callback,
    })
  end
end

function Sidebar:_with_internal_close(callback)
  self._internal_close = true
  local ok, err = pcall(callback)
  self._internal_close = false
  self:_clear_winclosed()
  if not ok then
    error(err, 0)
  end
end

function Sidebar:_bind_keymaps()
  local function selected(handler)
    return function()
      local row_value = self:selected_row()
      if row_value then
        handler(row_value)
      end
    end
  end

  local bindings = {
    jump_or_toggle = selected(self._handlers.activate),
    note = selected(self._handlers.note),
    toggle = selected(self._handlers.toggle),
    save = self._handlers.save,
    load = self._handlers.load,
    close = self._handlers.close,
  }
  for name, callback in pairs(bindings) do
    each_lhs(self._keymaps[name], function(lhs)
      self._popup:map("n", lhs, callback, { noremap = true, nowait = true, silent = true })
    end)
  end
end

function Sidebar:_create_popup(geometry)
  local layout = popup_layout(self._config, geometry)
  self._popup = self._popup_factory(vim.tbl_extend("force", layout, {
    border = self._config.border,
    enter = false,
    focusable = true,
    buf_options = {
      buftype = "nofile",
      bufhidden = "hide",
      swapfile = false,
      modifiable = false,
      readonly = true,
      filetype = "voyager",
    },
  }))
  self:_bind_keymaps()
end

function Sidebar:_open(opts, geometry)
  if not self._popup then
    self:_create_popup(geometry)
    self._popup:mount()
  else
    self._popup:update_layout(popup_layout(self._config, geometry))
    self._popup:show()
  end
  self._geometry = geometry
  self._tabpage = opts.tabpage
  self._mounted = true
  self:_bind_winclosed()
  if opts.focus then
    self:focus()
  end
  return true
end

function Sidebar:mount(opts)
  opts = opts or {}
  local geometry, reason = M.compute_geometry(self._config, self._ui_state())
  if not geometry then
    return nil, reason
  end
  if self._mounted then
    if opts.focus then
      self:focus()
    end
    return true
  end

  local ok, result = pcall(function()
    return self:_open(opts, geometry)
  end)
  if not ok then
    self:unmount({ owned = true })
    return nil, tostring(result)
  end
  return result
end

function Sidebar:remount(opts)
  opts = opts or {}
  local geometry, reason = M.compute_geometry(self._config, self._ui_state())
  if not geometry then
    if self._mounted and self._popup then
      self:_with_internal_close(function()
        self._popup:hide()
      end)
      self._mounted = false
    end
    return nil, reason
  end
  if self._mounted then
    self:_with_internal_close(function()
      self._popup:hide()
    end)
    self._mounted = false
  end
  return self:mount(opts)
end

function Sidebar:unmount(opts)
  opts = opts or {}
  if not self._popup then
    self._mounted = false
    return
  end

  local popup = self._popup
  if opts.owned then
    self:_with_internal_close(function()
      popup:unmount()
    end)
  else
    popup:unmount()
  end
  self:_clear_winclosed()
  self._popup = nil
  self._mounted = false
  self._line_to_row = {}
end

function Sidebar:render(flow, status)
  if not self._popup or not self._popup.bufnr or not vim.api.nvim_buf_is_valid(self._popup.bufnr) then
    return
  end

  local previous = self:selected_row()
  local width = content_size(self._config, assert(self._geometry)).width
  local rows, header = M.project(flow, width, status)
  local hidden_action_id = previous and hidden_by_action(flow, previous.owner_id) or nil
  local selected_index =
    M.selection_index(rows, previous and previous.kind or nil, previous and previous.owner_id or nil, hidden_action_id)

  local lines = { header }
  local line_to_row = { false }
  for _, row_value in ipairs(rows) do
    table.insert(lines, row_value.text)
    table.insert(line_to_row, row_value)
  end

  local bufnr = self._popup.bufnr
  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  self._line_to_row = line_to_row
  set_popup_cursor(self._popup, { selected_index + 1, 0 })
end

function Sidebar:focus()
  if not self:is_mounted() then
    return false
  end
  if self._popup.focus then
    self._popup:focus()
    return true
  end
  if self._popup.winid and vim.api.nvim_win_is_valid(self._popup.winid) then
    vim.api.nvim_set_current_win(self._popup.winid)
    return true
  end
  return false
end

function Sidebar:is_mounted()
  return self._mounted and self._popup ~= nil and self._popup.winid ~= nil
end

function Sidebar:owns_window(winid)
  return self._popup ~= nil and self._popup.winid == winid
end

function Sidebar:selected_row()
  if not self._popup then
    return nil
  end
  local cursor = popup_cursor(self._popup)
  return cursor and self._line_to_row[cursor[1]] or nil
end

return M
