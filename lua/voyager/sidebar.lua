local Actions = require("voyager.lsp.actions")

local M = {}
local Sidebar = {}
Sidebar.__index = Sidebar

local namespace = vim.api.nvim_create_namespace("voyager-sidebar")
local relation_namespace = vim.api.nvim_create_namespace("voyager-sidebar-relations")

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
  VoyagerRelationFocus = { link = "Visual" },
  VoyagerRelationHeader = { link = "CursorLine" },
  VoyagerRelationOrigin = { link = "DiagnosticInfo" },
  VoyagerRelationTarget = { link = "DiagnosticHint" },
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

local function relation_key(origin_id, method)
  return "relation:" .. origin_id .. ":" .. method
end

local function group_key(action_id)
  return "group:" .. action_id .. ":tests"
end

local function row(opts, width)
  local truncated = truncate_segments(opts.segments, width)
  local result = vim.tbl_extend("force", {}, opts, {
    text = segments_text(truncated),
    segments = truncated,
    -- Retained for consumers that inspect the old field. Semantic tree depth
    -- is deliberately absent from the flat presentation.
    depth = 0,
  })
  assert(type(result.key) == "string" and result.key ~= "", "Voyager sidebar rows require a stable key")
  return result
end

local function action_record(method)
  local name, record = Actions.by_method(method)
  return name, record
end

local function renders_above_method(method)
  local _, record = action_record(method)
  return record ~= nil and record.placement == "above"
end

local function target_ids_for(flow, action)
  local ids
  if type(flow.action_target_ids) == "function" then
    local ok, value = pcall(flow.action_target_ids, flow, action)
    if ok and type(value) == "table" then
      ids = value
    end
  end
  if ids == nil and type(action.target_ids) == "table" then
    ids = action.target_ids
  end
  if ids == nil then
    ids = {}
    for _, result in ipairs(action.results or {}) do
      table.insert(ids, result.id)
    end
  end

  local result = {}
  local seen = {}
  for _, id in ipairs(ids) do
    if type(id) == "string" and id ~= "" and not seen[id] then
      seen[id] = true
      table.insert(result, id)
    end
  end
  return result
end

local function is_storage_action(action)
  local _, record = action_record(action.method)
  return record ~= nil and record.storage == true
end

local function relation_title(method, fallback_label, symbol)
  local _, record = action_record(method)
  local label = record and record.label or fallback_label
  if record and record.direction == "outgoing" then
    return label .. " from " .. symbol
  end
  return label .. " of " .. symbol
end

local function relation_state_segments(value)
  if type(value) ~= "table" then
    return {}
  end
  if value.state == "loading" then
    return { segment(" · loading…", "VoyagerRequests") }
  end
  if value.state == "error" then
    local message = type(value.message) == "string" and value.message ~= "" and value.message or "failed"
    return { segment(" · " .. message, "VoyagerStale") }
  end
  return {}
end

function M.project(flow, width, status, display)
  status = status or {}
  assert(type(display) == "table", "Voyager sidebar display options are required")
  local icons = display.icons
  assert(type(icons) == "table", "Voyager sidebar icons are required")
  local rows = {}

  if flow == nil then
    table.insert(
      rows,
      row({
        kind = "hint",
        owner_id = "",
        key = "hint:waiting",
        segments = { segment("  navigate to start recording", "VoyagerPath") },
      }, width)
    )
    local waiting = truncate_segments({ segment("Voyager · (waiting)", "VoyagerHeader") }, width)
    return rows, { text = segments_text(waiting), segments = waiting }
  end

  local expanded_test_groups = status.expanded_test_groups or {}
  local relation_statuses = {}
  local transients_by_origin = {}
  for map_key, value in pairs(status.relations or {}) do
    if type(value) == "table" and type(value.origin_id) == "string" and type(value.method) == "string" then
      local key = relation_key(value.origin_id, value.method)
      relation_statuses[key] = value
      local values = transients_by_origin[value.origin_id] or {}
      table.insert(values, {
        map_key = tostring(map_key),
        key = key,
        value = value,
      })
      transients_by_origin[value.origin_id] = values
    end
  end
  for _, values in pairs(transients_by_origin) do
    table.sort(values, function(left, right)
      if left.value.method ~= right.value.method then
        return left.value.method < right.value.method
      end
      return left.map_key < right.map_key
    end)
  end

  local ancestor_ids = {}
  for _, id in ipairs(flow:path_ids(flow.current_node_id)) do
    ancestor_ids[id] = true
  end

  local canonical_seen = {}
  local visit_location
  local visit_action

  local function location_node(id, fallback)
    if type(flow.location) == "function" then
      local found = flow:location(id)
      if found then
        return found
      end
    end
    return fallback
  end

  local projected_location_contains_current
  local function projected_action_contains_current(action, current_node_id, seen, known_target_ids)
    local owned_by_id = {}
    for _, result in ipairs(action.results or {}) do
      owned_by_id[result.id] = result
    end
    for _, target_id in ipairs(known_target_ids or target_ids_for(flow, action)) do
      if target_id == current_node_id then
        return true
      end
      local target = location_node(target_id, owned_by_id[target_id])
      if target and projected_location_contains_current(target, current_node_id, seen) then
        return true
      end
    end
    return false
  end

  projected_location_contains_current = function(location, current_node_id, seen)
    if location.id == current_node_id then
      return true
    end
    seen = seen or {}
    if seen[location.id] then
      return false
    end
    seen[location.id] = true
    for _, action in ipairs(location.actions or {}) do
      if projected_action_contains_current(action, current_node_id, seen) then
        return true
      end
    end
    return false
  end

  local function marker_for_location(node)
    if node.id == flow.current_node_id then
      return "current", segment(badge(icons.current), "VoyagerCurrent")
    end
    if node.stale then
      return "stale", segment(badge(icons.stale), "VoyagerStale")
    end
    return nil, segment("  ")
  end

  local function append_location(node, key, metadata)
    local marker, glyph = marker_for_location(node)
    local location = node.location
    local symbol_hl = "VoyagerSymbol"
    if ancestor_ids[node.id] then
      symbol_hl = "VoyagerAncestor"
    elseif node.visited then
      symbol_hl = "VoyagerVisited"
    end
    local kind_icon = location.symbol_kind and icons.kinds and icons.kinds[location.symbol_kind] or nil
    local location_row = row(
      vim.tbl_extend("force", {
        kind = "location",
        owner_id = node.id,
        key = key,
        context_location_id = node.id,
        location_id = node.id,
        marker = marker,
        visited = node.visited == true,
        segments = {
          glyph,
          segment(badge(kind_icon), "VoyagerIcon"),
          segment(location.symbol, symbol_hl),
          segment(" — ", "VoyagerPath"),
          segment(
            locator_text(location.locator, display.path) .. ":" .. (location.range.start.line + 1),
            "VoyagerPath"
          ),
        },
      }, metadata or {}),
      width
    )
    table.insert(rows, location_row)
  end

  local function append_note(node, occurrence_key, metadata)
    if not node.note then
      return
    end
    table.insert(
      rows,
      row(
        vim.tbl_extend("force", {
          kind = "note",
          owner_id = node.id,
          key = "note:" .. occurrence_key,
          context_location_id = node.id,
          location_id = node.id,
          marker = "note",
          segments = {
            segment("  "),
            segment(badge(icons.note) .. node.note, "VoyagerNote"),
          },
        }, metadata or {}),
        width
      )
    )
  end

  local function append_alias(target, action, origin, alias)
    append_location(target, "location:" .. action.id .. ":" .. target.id, {
      alias = alias == true,
      canonical = alias ~= true,
      origin_id = origin.id,
      action_id = action.id,
      method = action.method,
    })
  end

  local function append_transient(origin, relation)
    local value = relation.value
    local above = renders_above_method(value.method)
    local action_name = action_record(value.method)
    local segments = {
      segment("  "),
      segment("  ", "VoyagerDisclosure"),
      segment(badge(above and icons.caller or icons.callee), above and "VoyagerDirectionUp" or "VoyagerDirectionDown"),
      segment(badge(action_name and icons[action_name]), "VoyagerIcon"),
      segment(relation_title(value.method, value.label, origin.location.symbol), "VoyagerActionLabel"),
    }
    vim.list_extend(segments, relation_state_segments(value))
    table.insert(
      rows,
      row({
        kind = "relation",
        owner_id = origin.id,
        key = relation.key,
        context_location_id = origin.id,
        origin_id = origin.id,
        method = value.method,
        action_id = nil,
        target_ids = {},
        state = value.state,
        message = value.message,
        segments = segments,
      }, width)
    )
  end

  local function append_relation_status(segments, action, state)
    vim.list_extend(segments, relation_state_segments(state))
    if type(state) ~= "table" and action.query_status == "partial" then
      table.insert(segments, segment(" · partial", "VoyagerStale"))
    end
  end

  visit_action = function(action, origin)
    local target_ids = target_ids_for(flow, action)
    local key = relation_key(origin.id, action.method)
    local relation_status = relation_statuses[key]
    local marker
    local current_glyph = segment("  ")
    if action.collapsed and projected_action_contains_current(action, flow.current_node_id, {}, target_ids) then
      marker = "descendant_current"
      current_glyph = segment(badge(icons.current), "VoyagerCurrent")
    end
    local above = renders_above_method(action.method)
    local action_name, record = action_record(action.method)
    local label = record and record.label or action.label
    local segments = {
      current_glyph,
      segment(badge(action.collapsed and icons.collapsed or icons.expanded), "VoyagerDisclosure"),
      segment(badge(above and icons.caller or icons.callee), above and "VoyagerDirectionUp" or "VoyagerDirectionDown"),
      segment(badge(action_name and icons[action_name]), "VoyagerIcon"),
      segment(relation_title(action.method, label, origin.location.symbol), "VoyagerActionLabel"),
      segment(" (" .. #target_ids .. ")", "VoyagerCount"),
    }
    append_relation_status(segments, action, relation_status)
    table.insert(
      rows,
      row({
        kind = "action",
        owner_id = action.id,
        key = key,
        context_location_id = origin.id,
        origin_id = origin.id,
        method = action.method,
        action_id = action.id,
        target_ids = vim.deepcopy(target_ids),
        marker = marker,
        state = relation_status and relation_status.state or action.query_status,
        message = relation_status and relation_status.message or nil,
        segments = segments,
      }, width)
    )
    if action.collapsed then
      return
    end

    local owned_by_id = {}
    for _, result in ipairs(action.results or {}) do
      owned_by_id[result.id] = result
    end
    local direct = {}
    local tests = {}
    for _, target_id in ipairs(target_ids) do
      local target = location_node(target_id, owned_by_id[target_id])
      if target then
        local entry = { id = target_id, node = target, owned = owned_by_id[target_id] }
        if M.is_test_location(target.location, display.test_paths) then
          table.insert(tests, entry)
        else
          table.insert(direct, entry)
        end
      end
    end

    local function render_target(entry)
      local metadata = {
        origin_id = origin.id,
        action_id = action.id,
        method = action.method,
      }
      -- A canonical location's relations belong to its first visible
      -- occurrence. That occurrence may be a cross-link while the storage
      -- owner is folded; later occurrences stay alias-only.
      if not canonical_seen[entry.id] then
        visit_location(entry.node, "location:" .. action.id .. ":" .. entry.id, metadata)
      else
        append_alias(entry.node, action, origin, true)
      end
    end

    for _, entry in ipairs(direct) do
      render_target(entry)
    end
    if #tests > 0 then
      local expanded = expanded_test_groups[action.id] == true
      local group_marker
      local group_glyph = segment("  ")
      local tests_contain_current = false
      for _, entry in ipairs(tests) do
        if entry.id == flow.current_node_id then
          tests_contain_current = true
          break
        end
        if projected_location_contains_current(entry.node, flow.current_node_id, {}) then
          tests_contain_current = true
          break
        end
      end
      if not expanded and tests_contain_current then
        group_marker = "descendant_current"
        group_glyph = segment(badge(icons.current), "VoyagerCurrent")
      end
      local test_ids = vim.tbl_map(function(entry)
        return entry.id
      end, tests)
      table.insert(
        rows,
        row({
          kind = "group",
          owner_id = action.id,
          key = group_key(action.id),
          context_location_id = origin.id,
          origin_id = origin.id,
          action_id = action.id,
          method = action.method,
          target_ids = test_ids,
          marker = group_marker,
          segments = {
            group_glyph,
            segment(badge(expanded and icons.expanded or icons.collapsed), "VoyagerDisclosure"),
            segment("tests", "VoyagerActionLabel"),
            segment(" (" .. #tests .. ")", "VoyagerCount"),
          },
        }, width)
      )
      if expanded then
        for _, entry in ipairs(tests) do
          render_target(entry)
        end
      end
    end
  end

  visit_location = function(node, occurrence_key, metadata)
    canonical_seen[node.id] = true
    local committed = {}
    for _, action in ipairs(node.actions or {}) do
      if not is_storage_action(action) then
        committed[action.method] = true
      end
      if not is_storage_action(action) and renders_above_method(action.method) then
        visit_action(action, node)
      end
    end
    local transient_seen = {}
    for _, relation in ipairs(transients_by_origin[node.id] or {}) do
      local method = relation.value.method
      if not committed[method] and not transient_seen[method] and renders_above_method(method) then
        transient_seen[method] = true
        append_transient(node, relation)
      end
    end

    append_location(
      node,
      occurrence_key,
      vim.tbl_extend("force", {
        alias = false,
        canonical = true,
      }, metadata or {})
    )
    append_note(node, occurrence_key, metadata)

    for _, action in ipairs(node.actions or {}) do
      if not is_storage_action(action) and not renders_above_method(action.method) then
        visit_action(action, node)
      end
    end
    for _, relation in ipairs(transients_by_origin[node.id] or {}) do
      local method = relation.value.method
      if not committed[method] and not transient_seen[method] and not renders_above_method(method) then
        transient_seen[method] = true
        append_transient(node, relation)
      end
    end
  end

  visit_location(flow.root, "location:" .. flow.root.id)

  -- Exact refreshes can unlink a previously returned location without
  -- deleting the canonical record that owns its notes or relations. Keep
  -- those records reachable in an explicit history section instead of
  -- silently dropping data from the projection.
  local linked = {}
  local function mark_linked(node)
    if not node or linked[node.id] then
      return
    end
    linked[node.id] = true
    for _, action in ipairs(node.actions or {}) do
      for _, target_id in ipairs(target_ids_for(flow, action)) do
        mark_linked(location_node(target_id))
      end
    end
  end
  mark_linked(flow.root)

  local detached = {}
  local detached_by_id = {}
  for _, node in ipairs(flow:dfs()) do
    if node.kind == "location" and not linked[node.id] then
      table.insert(detached, node)
      detached_by_id[node.id] = node
    end
  end
  if #detached > 0 then
    table.insert(
      rows,
      row({
        kind = "history",
        owner_id = flow.root.id,
        key = "group:history",
        target_ids = vim.tbl_map(function(node)
          return node.id
        end, detached),
        segments = {
          segment("  "),
          segment("unlinked history", "VoyagerActionLabel"),
          segment(" (" .. #detached .. ")", "VoyagerCount"),
        },
      }, width)
    )
    local covered = {}
    local function cover(node)
      if covered[node.id] then
        return
      end
      covered[node.id] = true
      for _, action in ipairs(node.actions or {}) do
        for _, target_id in ipairs(target_ids_for(flow, action)) do
          local target = detached_by_id[target_id]
          if target then
            cover(target)
          end
        end
      end
    end
    for _, node in ipairs(detached) do
      if not covered[node.id] then
        visit_location(node, "location:history:" .. node.id, { detached = true })
        cover(node)
      end
    end
  end

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

function M.selection_index(rows, previous_key, hidden_under_key, previous)
  for index, candidate in ipairs(rows) do
    if candidate.key == previous_key then
      return index
    end
  end
  if hidden_under_key then
    for index, candidate in ipairs(rows) do
      if candidate.key == hidden_under_key then
        return index
      end
    end
  end

  -- Async refreshes and unlinking can replace an occurrence key while the
  -- represented symbol remains visible elsewhere. Prefer that semantic
  -- location, then its owning relation/origin, before falling back to the top.
  if type(previous) == "table" then
    local location_id = previous.location_id
    if type(location_id) == "string" then
      for index, candidate in ipairs(rows) do
        if candidate.kind == "location" and candidate.location_id == location_id then
          return index
        end
      end
    end
    if type(previous.origin_id) == "string" and type(previous.method) == "string" then
      local key = relation_key(previous.origin_id, previous.method)
      for index, candidate in ipairs(rows) do
        if candidate.key == key then
          return index
        end
      end
    end
    local context_id = previous.context_location_id
    if type(context_id) == "string" then
      for index, candidate in ipairs(rows) do
        if candidate.kind == "location" and candidate.location_id == context_id then
          return index
        end
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

-- Find the visible relation/group row that now hides the previous occurrence,
-- so a collapse has a deterministic cursor fallback.
local function hidden_under_row(flow, previous, opts)
  if type(previous) ~= "table" then
    return nil
  end
  if previous.action_id then
    local action = flow:find(previous.action_id)
    if action and action.kind == "action" then
      if action.collapsed then
        return relation_key(previous.origin_id or previous.context_location_id, action.method)
      end
      local location = flow:location(previous.context_location_id)
      if
        previous.kind == "location"
        and location
        and M.is_test_location(location.location, opts.test_paths)
        and opts.expanded_test_groups[action.id] ~= true
      then
        return group_key(action.id)
      end
    end
  end

  local owner_id = previous.context_location_id or previous.owner_id
  local visited = {}
  local function visit_location(location, hidden_key)
    if visited[location.id] then
      return nil
    end
    visited[location.id] = true
    if location.id == owner_id then
      return hidden_key
    end
    for _, action in ipairs(location.actions or {}) do
      if action.id == previous.owner_id then
        return hidden_key
      end
      local action_hidden = hidden_key
      if not action_hidden and action.collapsed then
        action_hidden = relation_key(location.id, action.method)
      end
      for _, result in ipairs(action.results or {}) do
        local result_hidden = action_hidden
        if
          not result_hidden
          and M.is_test_location(result.location, opts.test_paths)
          and opts.expanded_test_groups[action.id] ~= true
        then
          result_hidden = group_key(action.id)
        end
        local found = visit_location(result, result_hidden)
        if found ~= nil then
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
  self._relationship_lens_active = false
  self:_clear_relationship_lens_marks()
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
    show_callers = self._handlers.show_callers and selected(self._handlers.show_callers) or nil,
    show_callees = self._handlers.show_callees and selected(self._handlers.show_callees) or nil,
    refresh_callers = self._handlers.refresh_callers and selected(self._handlers.refresh_callers) or nil,
    refresh_callees = self._handlers.refresh_callees and selected(self._handlers.refresh_callees) or nil,
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
    if type(callback) == "function" then
      each_lhs(self._keymaps[name], function(lhs)
        self._popup:map("n", lhs, callback, { noremap = true, nowait = true, silent = true })
      end)
    end
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

function Sidebar:_clear_relationship_lens_marks()
  local bufnr = self._popup and self._popup.bufnr or nil
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, relation_namespace, 0, -1)
  end
end

function Sidebar:_update_relationship_lens()
  local bufnr = self._popup and self._popup.bufnr or nil
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, relation_namespace, 0, -1)

  local selected = self:selected_row()
  if not selected then
    return
  end

  local location_lines = {}
  local relation_rows = {}
  local selected_line
  for line, row_value in pairs(self._line_to_row) do
    if row_value and row_value == selected then
      selected_line = line
    end
    if row_value and row_value.kind == "location" and type(row_value.context_location_id) == "string" then
      local lines = location_lines[row_value.context_location_id] or {}
      table.insert(lines, line)
      location_lines[row_value.context_location_id] = lines
    elseif row_value and (row_value.kind == "action" or row_value.kind == "relation") then
      table.insert(relation_rows, { line = line, row = row_value })
    end
  end

  local marks = {}
  local function mark(line, group, rank)
    if not line then
      return
    end
    local current = marks[line]
    if not current or rank > current.rank then
      marks[line] = { group = group, rank = rank }
    end
  end
  local function mark_location(id, group, rank)
    for _, line in ipairs(location_lines[id] or {}) do
      mark(line, group, rank)
    end
  end
  local function targets_include(row_value, id)
    for _, target_id in ipairs(row_value.target_ids or {}) do
      if target_id == id then
        return true
      end
    end
    return false
  end
  local function mark_relation_endpoints(row_value)
    mark_location(row_value.origin_id, "VoyagerRelationOrigin", 20)
    for _, target_id in ipairs(row_value.target_ids or {}) do
      mark_location(target_id, "VoyagerRelationTarget", 10)
    end
  end

  if selected.kind == "action" or selected.kind == "relation" or selected.kind == "group" then
    mark(selected_line, "VoyagerRelationFocus", 40)
    mark_relation_endpoints(selected)
  elseif selected.kind == "location" or selected.kind == "note" then
    local location_id = selected.context_location_id or selected.owner_id
    mark_location(location_id, "VoyagerRelationFocus", 40)
    if selected.kind == "note" then
      mark(selected_line, "VoyagerRelationFocus", 40)
    end
    for _, entry in ipairs(relation_rows) do
      local relation = entry.row
      if relation.origin_id == location_id then
        mark(entry.line, "VoyagerRelationHeader", 30)
        for _, target_id in ipairs(relation.target_ids or {}) do
          mark_location(target_id, "VoyagerRelationTarget", 10)
        end
      elseif targets_include(relation, location_id) then
        mark(entry.line, "VoyagerRelationHeader", 30)
        mark_location(relation.origin_id, "VoyagerRelationOrigin", 20)
      end
    end
  end

  for line, value in pairs(marks) do
    vim.api.nvim_buf_set_extmark(bufnr, relation_namespace, line - 1, 0, {
      line_hl_group = value.group,
      priority = 90,
    })
  end
end

function Sidebar:_bind_relationship_lens()
  if not self._popup or not self._popup.bufnr or self._relationship_autocmds then
    return
  end
  self._relationship_autocmds = {
    vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
      buffer = self._popup.bufnr,
      callback = function()
        self._relationship_lens_active = true
        self:_update_relationship_lens()
      end,
    }),
    vim.api.nvim_create_autocmd("BufLeave", {
      buffer = self._popup.bufnr,
      callback = function()
        self._relationship_lens_active = false
        self:_clear_relationship_lens_marks()
      end,
    }),
  }
end

function Sidebar:_clear_relationship_lens()
  self._relationship_lens_active = false
  self:_clear_relationship_lens_marks()
  for _, autocmd in ipairs(self._relationship_autocmds or {}) do
    pcall(vim.api.nvim_del_autocmd, autocmd)
  end
  self._relationship_autocmds = nil
end

function Sidebar:_open(opts, envelope)
  self._envelope = envelope
  local fitted = M.fit(self._config, envelope, self._content)
  if not self._popup then
    self:_create_popup(fitted)
    self._popup:mount()
    self:_bind_follow_preview()
    self:_bind_relationship_lens()
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
  self:_clear_relationship_lens()
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
  local hidden_under_key = previous
      and flow
      and hidden_under_row(flow, previous, {
        test_paths = self._config.test_paths,
        expanded_test_groups = (status or {}).expanded_test_groups or {},
      })
    or nil
  local selected_index = M.selection_index(rows, previous and previous.key or nil, hidden_under_key, previous)

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
      vim.api.nvim_buf_set_extmark(bufnr, namespace, index, 0, {
        line_hl_group = "VoyagerCurrentLine",
        priority = 120,
      })
    end
  end

  self._line_to_row = line_to_row
  set_popup_cursor(self._popup, { selected_index + 1, 0 })
  if self._relationship_lens_active then
    self:_update_relationship_lens()
  else
    self:_clear_relationship_lens_marks()
  end
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
  { "jump_or_toggle", "jump to a location, or toggle a relation" },
  { "jump_stay", "jump but keep focus in the sidebar" },
  { "run_action", "record an LSP action from the selected node" },
  { "show_callers", "show callers, querying LSP when missing" },
  { "show_callees", "show calls, querying LSP when missing" },
  { "refresh_callers", "refresh callers from LSP" },
  { "refresh_callees", "refresh calls from LSP" },
  { "preview", "peek at the selected location" },
  { "delete", "unlink an occurrence; delete relation/history; clear note" },
  { "note", "add, edit, or remove a note" },
  { "save", "save or merge the flow" },
  { "load", "load a saved flow" },
  { "toggle", "collapse or expand the selected relation" },
  { "collapse_all", "collapse every relation" },
  { "expand_all", "expand every relation" },
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

function Sidebar:selected_key()
  local selected = self:selected_row()
  return selected and selected.key or nil
end

function Sidebar:focus_relation(origin_id, method)
  if not self:is_mounted() or type(origin_id) ~= "string" or type(method) ~= "string" then
    return false
  end
  local key = relation_key(origin_id, method)
  for line, row_value in ipairs(self._line_to_row) do
    if row_value and row_value.key == key then
      set_popup_cursor(self._popup, { line, 0 })
      self:focus()
      self._relationship_lens_active = true
      self:_update_relationship_lens()
      return true
    end
  end
  return false
end

return M
