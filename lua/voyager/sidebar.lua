local Actions = require("voyager.lsp.actions")

local M = {}
local Sidebar = {}
Sidebar.__index = Sidebar

local namespace = vim.api.nvim_create_namespace("voyager-sidebar")

local highlight_groups = {
  VoyagerHeader = { link = "Title" },
  VoyagerDirty = { link = "DiagnosticWarn" },
  VoyagerRequests = { link = "Comment" },
  VoyagerSymbol = { link = "Identifier" },
  VoyagerVisited = { link = "Comment" },
  VoyagerAncestor = { bold = true },
  VoyagerPath = { link = "Comment" },
  VoyagerActionLabel = { link = "Function" },
  VoyagerCount = { link = "Number" },
  VoyagerIcon = { link = "Special" },
  VoyagerDisclosure = { link = "NonText" },
  VoyagerDirectionUp = { link = "DiagnosticInfo" },
  VoyagerDirectionDown = { link = "DiagnosticHint" },
  VoyagerCurrent = { link = "DiagnosticOk" },
  VoyagerCurrentLine = { link = "CursorLine" },
  VoyagerStale = { link = "DiagnosticWarn" },
  VoyagerNote = { link = "DiagnosticHint" },
  VoyagerFlash = { link = "Visual" },
}

function M.setup_highlights()
  for name, definition in pairs(highlight_groups) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", { default = true }, definition))
  end
end

local function badge(icon)
  if type(icon) == "string" and icon ~= "" then
    return icon .. " "
  end
  return ""
end

local function segment(text, hl)
  return { text = text, hl = hl }
end

local function truncate_segments(segments, width)
  if width <= 0 then
    return { segment("") }
  end
  local total = 0
  for _, part in ipairs(segments) do
    total = total + vim.fn.strdisplaywidth(part.text)
  end
  if total <= width then
    return vim.deepcopy(segments)
  end
  local ellipsis = "…"
  local target = math.max(0, width - vim.fn.strdisplaywidth(ellipsis))
  local result = {}
  local used = 0
  for _, part in ipairs(segments) do
    local part_width = vim.fn.strdisplaywidth(part.text)
    if used + part_width <= target then
      table.insert(result, vim.deepcopy(part))
      used = used + part_width
    else
      local characters = vim.fn.strchars(part.text)
      while characters > 0 do
        local prefix = vim.fn.strcharpart(part.text, 0, characters)
        if vim.fn.strdisplaywidth(prefix) <= target - used then
          table.insert(result, segment(prefix, part.hl))
          break
        end
        characters = characters - 1
      end
      break
    end
  end
  table.insert(result, segment(ellipsis, "VoyagerPath"))
  return result
end

local function segments_text(segments)
  local text = {}
  for _, part in ipairs(segments) do
    table.insert(text, part.text)
  end
  return table.concat(text)
end

local function shorten_path(path)
  local parts = vim.split(path, "/", { plain = true })
  for index = 1, #parts - 1 do
    local head = vim.fn.strcharpart(parts[index], 0, 1)
    if head ~= "" then
      parts[index] = head
    end
  end
  return table.concat(parts, "/")
end

local function locator_text(locator, path_style)
  local value = locator.path or locator.uri or "<unknown>"
  if locator.uri ~= nil or path_style == nil or path_style == "relative" then
    return value
  end
  if path_style == "filename" then
    return value:match("([^/]+)/*$") or value
  end
  return shorten_path(value)
end

local locations_contain_current

local function contains_current(action, current_node_id)
  return locations_contain_current(action.results, current_node_id)
end

locations_contain_current = function(results, current_node_id)
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
  for _, result in ipairs(results) do
    if visit(result) then
      return true
    end
  end
  return false
end

function M.is_test_location(location, test_paths)
  local value = location.locator.path or location.locator.uri
  if type(value) ~= "string" then
    return false
  end
  -- Project locators are relative, so directory patterns like "/src/test/"
  -- also run against a slash-prefixed copy.
  local rooted = value:sub(1, 1) == "/" and value or ("/" .. value)
  for _, pattern in ipairs(test_paths or {}) do
    if value:find(pattern) or rooted:find(pattern) then
      return true
    end
  end
  return false
end

local function row(kind, owner_id, segments, depth, marker, width)
  local truncated = truncate_segments(segments, width)
  return {
    kind = kind,
    owner_id = owner_id,
    text = segments_text(truncated),
    segments = truncated,
    depth = depth,
    marker = marker,
  }
end

function M.project(flow, width, status, display)
  status = status or {}
  assert(type(display) == "table", "Voyager sidebar display options are required")
  local icons = display.icons
  assert(type(icons) == "table", "Voyager sidebar icons are required")
  local indent_unit = string.rep(" ", display.indent or 1)
  local function indent(depth)
    return segment(string.rep(indent_unit, depth))
  end
  local rows = {}

  if flow == nil then
    local hint = row("hint", "", { segment("  navigate to start recording", "VoyagerPath") }, 0, nil, width)
    table.insert(rows, hint)
    local waiting = truncate_segments({ segment("Voyager · (waiting)", "VoyagerHeader") }, width)
    return rows, { text = segments_text(waiting), segments = waiting }
  end

  local expanded_test_groups = status.expanded_test_groups or {}

  local ancestor_ids = {}
  for _, id in ipairs(flow:path_ids(flow.current_node_id)) do
    ancestor_ids[id] = true
  end

  local visit_location
  local visit_action

  local function renders_above(action)
    local _, record = Actions.by_method(action.method)
    return record ~= nil and record.placement == "above"
  end

  visit_location = function(node, depth)
    -- Caller-producing actions render above their symbol so the projected
    -- rows read top-down along the call flow: entry points first, then the
    -- symbol, then everything it leads to. Action rows share their symbol's
    -- indent; only destinations step one level deeper, which keeps long
    -- exploration chains inside the card width.
    for _, action in ipairs(node.actions) do
      if renders_above(action) then
        visit_action(action, depth)
      end
    end
    local marker
    local glyph = segment("  ")
    if node.id == flow.current_node_id then
      marker = "current"
      glyph = segment(badge(icons.current), "VoyagerCurrent")
    elseif node.stale then
      marker = "stale"
      glyph = segment(badge(icons.stale), "VoyagerStale")
    end
    local location = node.location
    local symbol_hl = "VoyagerSymbol"
    if ancestor_ids[node.id] then
      symbol_hl = "VoyagerAncestor"
    elseif node.visited then
      symbol_hl = "VoyagerVisited"
    end
    local kind_icon = location.symbol_kind and icons.kinds and icons.kinds[location.symbol_kind] or nil
    local segments = {
      indent(depth),
      glyph,
      segment(badge(kind_icon), "VoyagerIcon"),
      segment(location.symbol, symbol_hl),
      segment(" — ", "VoyagerPath"),
      segment(locator_text(location.locator, display.path) .. ":" .. (location.range.start.line + 1), "VoyagerPath"),
    }
    local location_row = row("location", node.id, segments, depth, marker, width)
    location_row.visited = node.visited == true
    table.insert(rows, location_row)
    if node.note then
      local note_depth = depth + 1
      local note_segments = {
        indent(note_depth),
        segment(badge(icons.note) .. node.note, "VoyagerNote"),
      }
      table.insert(rows, row("note", node.id, note_segments, note_depth, "note", width))
    end
    for _, action in ipairs(node.actions) do
      if not renders_above(action) then
        visit_action(action, depth)
      end
    end
  end

  visit_action = function(node, depth)
    local marker
    local current_glyph = segment("")
    if node.collapsed and contains_current(node, flow.current_node_id) then
      marker = "descendant_current"
      current_glyph = segment(badge(icons.current), "VoyagerCurrent")
    end
    local above = renders_above(node)
    local action_name = Actions.by_method(node.method)
    local segments = {
      indent(depth),
      current_glyph,
      segment(badge(node.collapsed and icons.collapsed or icons.expanded), "VoyagerDisclosure"),
      segment(badge(above and icons.caller or icons.callee), above and "VoyagerDirectionUp" or "VoyagerDirectionDown"),
      segment(badge(action_name and icons[action_name]), "VoyagerIcon"),
      segment(node.label, "VoyagerActionLabel"),
      segment(" (" .. #node.results .. ")", "VoyagerCount"),
    }
    table.insert(rows, row("action", node.id, segments, depth, marker, width))
    if node.collapsed then
      return
    end

    -- Test-file results are kept out of the way beneath a fold-by-default
    -- "tests" group so real code sites stay in view.
    local direct = {}
    local tests = {}
    for _, result in ipairs(node.results) do
      if M.is_test_location(result.location, display.test_paths) then
        table.insert(tests, result)
      else
        table.insert(direct, result)
      end
    end
    for _, result in ipairs(direct) do
      visit_location(result, depth + 1)
    end
    if #tests > 0 then
      local expanded = expanded_test_groups[node.id] == true
      local group_marker
      local group_glyph = segment("")
      if not expanded and locations_contain_current(tests, flow.current_node_id) then
        group_marker = "descendant_current"
        group_glyph = segment(badge(icons.current), "VoyagerCurrent")
      end
      local group_segments = {
        indent(depth + 1),
        group_glyph,
        segment(badge(expanded and icons.expanded or icons.collapsed), "VoyagerDisclosure"),
        segment("tests", "VoyagerActionLabel"),
        segment(" (" .. #tests .. ")", "VoyagerCount"),
      }
      table.insert(rows, row("group", node.id, group_segments, depth + 1, group_marker, width))
      if expanded then
        for _, result in ipairs(tests) do
          visit_location(result, depth + 2)
        end
      end
    end
  end

  visit_location(flow.root, 0)

  local header_segments = { segment("Voyager · " .. flow.name, "VoyagerHeader") }
  if status.dirty then
    table.insert(header_segments, segment(" *", "VoyagerDirty"))
  end
  local count = status.request_count or 0
  if count > 0 then
    table.insert(
      header_segments,
      segment(string.format(" · %d request%s", count, count == 1 and "" or "s"), "VoyagerRequests")
    )
  end
  header_segments = truncate_segments(header_segments, width)
  return rows, { text = segments_text(header_segments), segments = header_segments }
end

function M.selection_index(rows, previous_kind, previous_owner_id, hidden_under)
  for index, candidate in ipairs(rows) do
    if candidate.kind == previous_kind and candidate.owner_id == previous_owner_id then
      return index
    end
  end
  if hidden_under then
    for index, candidate in ipairs(rows) do
      if candidate.kind == hidden_under.kind and candidate.owner_id == hidden_under.owner_id then
        return index
      end
    end
  end
  return 1
end

function M.compute_envelope(config, ui_state)
  if ui_state.columns < 24 then
    return nil, "editor must be at least 24 columns wide"
  end

  local height = ui_state.lines - ui_state.tabline_rows - ui_state.statusline_rows - ui_state.cmdheight
  if height < 4 then
    return nil, "editor must have at least 4 usable rows"
  end

  return {
    row = ui_state.tabline_rows,
    columns = ui_state.columns,
    side = config.side,
    max_width = math.min(config.width, ui_state.columns - 2),
    max_height = height,
  }
end

local function border_cells(config)
  if config.border == "none" then
    return 0
  end
  return 2
end

function M.fit(config, envelope, content)
  local cells = border_cells(config)
  local content_width = content and content.width or 0
  local content_height = content and content.height or 1
  local width = math.min(envelope.max_width, math.max(20, content_width + cells))
  local height = math.min(envelope.max_height, math.max(1 + cells, content_height + cells))
  return {
    row = envelope.row,
    col = envelope.side == "left" and 0 or envelope.columns - width,
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

local function popup_layout(config, geometry)
  local cells = border_cells(config)
  return {
    relative = "editor",
    position = { row = geometry.row, col = geometry.col },
    size = {
      width = geometry.width - cells,
      height = geometry.height - cells,
    },
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

-- Find the visible row (collapsed action or folded test group) that hides
-- `owner_id`, so the cursor can fall back to it after a re-render.
local function hidden_under_row(flow, owner_id, opts)
  local function visit_location(location, hidden)
    if location.id == owner_id then
      return hidden
    end
    for _, action in ipairs(location.actions) do
      if action.id == owner_id then
        return hidden
      end
      local action_hidden = hidden
      if not action_hidden and action.collapsed then
        action_hidden = { kind = "action", owner_id = action.id }
      end
      for _, result in ipairs(action.results) do
        local result_hidden = action_hidden
        if
          not result_hidden
          and M.is_test_location(result.location, opts.test_paths)
          and opts.expanded_test_groups[action.id] ~= true
        then
          result_hidden = { kind = "group", owner_id = action.id }
        end
        local found = visit_location(result, result_hidden)
        if found ~= nil then
          return found
        end
      end
    end
  end
  return visit_location(flow.root, false) or nil
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
  assert(type(opts.sidebar.icons) == "table", "Voyager sidebar icons are required")
  assert(type(opts.keymaps) == "table", "Voyager sidebar keymaps are required")
  assert(type(opts.handlers) == "table", "Voyager sidebar handlers are required")
  assert(type(opts.notify) == "function", "Voyager sidebar notification adapter is required")
  M.setup_highlights()

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
  self:close_preview()
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
    jump_stay = selected(self._handlers.activate_stay),
    run_action = selected(self._handlers.run_action),
    delete = selected(self._handlers.delete),
    preview = selected(self._handlers.preview),
    note = selected(self._handlers.note),
    toggle = selected(self._handlers.toggle),
    collapse_all = self._handlers.collapse_all,
    expand_all = self._handlers.expand_all,
    save = self._handlers.save,
    load = self._handlers.load,
    close = self._handlers.close,
    help = function()
      self:show_help()
    end,
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

-- While the cursor rests on a location or note row the preview float stays
-- open and follows; it closes when the sidebar loses focus, not on movement.
function Sidebar:_bind_follow_preview()
  if self._config.preview == false or not self._popup.bufnr then
    return
  end
  self._follow_autocmds = self._follow_autocmds or {}
  table.insert(
    self._follow_autocmds,
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = self._popup.bufnr,
      callback = function()
        if self._handlers.cursor_row then
          self._handlers.cursor_row(self:selected_row())
        end
      end,
    })
  )
  table.insert(
    self._follow_autocmds,
    vim.api.nvim_create_autocmd("BufLeave", {
      buffer = self._popup.bufnr,
      callback = function()
        self:close_preview()
      end,
    })
  )
end

function Sidebar:_clear_follow_preview()
  for _, autocmd in ipairs(self._follow_autocmds or {}) do
    pcall(vim.api.nvim_del_autocmd, autocmd)
  end
  self._follow_autocmds = nil
end

function Sidebar:_open(opts, envelope)
  self._envelope = envelope
  local fitted = M.fit(self._config, envelope, self._content)
  if not self._popup then
    self:_create_popup(fitted)
    self._popup:mount()
    self:_bind_follow_preview()
  else
    self._popup:update_layout(popup_layout(self._config, fitted))
    self._popup:show()
  end
  self._geometry = fitted
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
  local envelope, reason = M.compute_envelope(self._config, self._ui_state())
  if not envelope then
    return nil, reason
  end
  if self._mounted then
    if opts.focus then
      self:focus()
    end
    return true
  end

  local ok, result = pcall(function()
    return self:_open(opts, envelope)
  end)
  if not ok then
    self:unmount({ owned = true })
    return nil, tostring(result)
  end
  return result
end

function Sidebar:remount(opts)
  opts = opts or {}
  local envelope, reason = M.compute_envelope(self._config, self._ui_state())
  if not envelope then
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
  self:close_preview()
  self:_clear_follow_preview()
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

function Sidebar:_fit_to_content(fitted)
  local geometry = self._geometry
  if
    self:is_mounted()
    and (
      not geometry
      or geometry.row ~= fitted.row
      or geometry.col ~= fitted.col
      or geometry.width ~= fitted.width
      or geometry.height ~= fitted.height
    )
  then
    self._popup:update_layout(popup_layout(self._config, fitted))
    self._geometry = fitted
  end
end

function Sidebar:render(flow, status)
  if not self._popup or not self._popup.bufnr or not vim.api.nvim_buf_is_valid(self._popup.bufnr) then
    return
  end

  local previous = self:selected_row()
  local cap = assert(self._envelope).max_width - border_cells(self._config)
  local rows, header = M.project(flow, cap, status, {
    icons = self._config.icons,
    path = self._config.path,
    indent = self._config.indent,
    test_paths = self._config.test_paths,
  })
  local hidden_under = previous
      and flow
      and hidden_under_row(flow, previous.owner_id, {
        test_paths = self._config.test_paths,
        expanded_test_groups = (status or {}).expanded_test_groups or {},
      })
    or nil
  local selected_index =
    M.selection_index(rows, previous and previous.kind or nil, previous and previous.owner_id or nil, hidden_under)

  local lines = { header.text }
  local annotated = { header.segments }
  local line_to_row = { false }
  for _, row_value in ipairs(rows) do
    table.insert(lines, row_value.text)
    table.insert(annotated, row_value.segments)
    table.insert(line_to_row, row_value)
  end

  local content_width = 0
  for _, line in ipairs(lines) do
    content_width = math.max(content_width, vim.fn.strdisplaywidth(line))
  end
  self._content = { width = content_width + 1, height = #lines }
  self:_fit_to_content(M.fit(self._config, self._envelope, self._content))

  local bufnr = self._popup.bufnr
  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true

  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  for line_index, segments in ipairs(annotated) do
    local col = 0
    for _, part in ipairs(segments) do
      local length = #part.text
      if part.hl and length > 0 then
        vim.api.nvim_buf_set_extmark(bufnr, namespace, line_index - 1, col, {
          end_col = col + length,
          hl_group = part.hl,
        })
      end
      col = col + length
    end
  end
  for index, row_value in ipairs(rows) do
    if row_value.marker == "current" then
      vim.api.nvim_buf_set_extmark(bufnr, namespace, index, 0, { line_hl_group = "VoyagerCurrentLine" })
    end
  end

  self._line_to_row = line_to_row
  set_popup_cursor(self._popup, { selected_index + 1, 0 })
end

function Sidebar:close_preview()
  if self._preview_autocmd then
    pcall(vim.api.nvim_del_autocmd, self._preview_autocmd)
    self._preview_autocmd = nil
  end
  local preview = self._preview
  self._preview = nil
  if preview and preview.winid and vim.api.nvim_win_is_valid(preview.winid) then
    pcall(vim.api.nvim_win_close, preview.winid, true)
  end
end

function Sidebar:show_preview(opts)
  if
    self._preview
    and type(opts) == "table"
    and opts.key ~= nil
    and self._preview.key == opts.key
    and self._preview.winid
    and vim.api.nvim_win_is_valid(self._preview.winid)
  then
    return true
  end
  self:close_preview()
  if not self:is_mounted() or type(opts) ~= "table" or type(opts.lines) ~= "table" or #opts.lines == 0 then
    return false
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, opts.lines)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].modifiable = false
  if type(opts.filetype) == "string" and opts.filetype ~= "" then
    vim.bo[bufnr].filetype = opts.filetype
  end
  if type(opts.focus_line) == "number" and opts.focus_line >= 1 and opts.focus_line <= #opts.lines then
    vim.api.nvim_buf_set_extmark(bufnr, namespace, opts.focus_line - 1, 0, { line_hl_group = "VoyagerCurrentLine" })
  end

  local geometry = assert(self._geometry)
  local envelope = assert(self._envelope)
  local width = 0
  for _, line in ipairs(opts.lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.max(20, math.min(width + 1, 70, math.max(20, envelope.columns - geometry.width - 4)))
  local height = math.max(1, math.min(#opts.lines, 12))
  local col
  if envelope.side == "right" then
    col = math.max(0, geometry.col - width - 2)
  else
    col = math.min(envelope.columns - width, geometry.col + geometry.width + 2)
  end

  local open_ok, winid = pcall(vim.api.nvim_open_win, bufnr, false, {
    relative = "editor",
    row = geometry.row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = self._config.border == "none" and "single" or self._config.border,
    title = opts.title,
    title_pos = "center",
    focusable = false,
  })
  if not open_ok then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    return false
  end
  self._preview = { winid = winid, bufnr = bufnr, key = opts.key }
  -- In follow mode the persistent BufLeave autocmd owns closing; the peek
  -- mode of a disabled follow preview still closes on the next cursor move.
  local close_events = self._config.preview == false and { "CursorMoved", "BufLeave" } or { "BufLeave" }
  self._preview_autocmd = vim.api.nvim_create_autocmd(close_events, {
    buffer = self._popup.bufnr,
    once = true,
    callback = function()
      self:close_preview()
    end,
  })
  return true
end

local help_entries = {
  { "jump_or_toggle", "jump to the location, or toggle an action" },
  { "jump_stay", "jump but keep focus in the sidebar" },
  { "run_action", "record an LSP action from the selected node" },
  { "preview", "peek at the selected location" },
  { "delete", "delete the selected branch or note" },
  { "note", "add, edit, or remove a note" },
  { "save", "save or merge the flow" },
  { "load", "load a saved flow" },
  { "toggle", "collapse or expand the selected action" },
  { "collapse_all", "collapse every action" },
  { "expand_all", "expand every action" },
  { "help", "show this help" },
  { "close", "close Voyager" },
}

function Sidebar:show_help()
  local lines = {}
  local key_width = 0
  local rendered = {}
  for _, entry in ipairs(help_entries) do
    local value = self._keymaps[entry[1]]
    local keys = {}
    each_lhs(value, function(lhs)
      table.insert(keys, lhs)
    end)
    if #keys > 0 then
      local display = table.concat(keys, ", ")
      key_width = math.max(key_width, vim.fn.strdisplaywidth(display))
      table.insert(rendered, { display, entry[2] })
    end
  end
  for _, entry in ipairs(rendered) do
    table.insert(lines, string.format(" %-" .. key_width .. "s  %s", entry[1], entry[2]))
  end
  return self:show_preview({ lines = lines, title = " Voyager keys " })
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
