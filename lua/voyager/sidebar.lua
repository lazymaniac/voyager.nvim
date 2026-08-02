local M = {}

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
    local text = string.rep("  ", depth)
      .. current_glyph
      .. disclosure
      .. node.label
      .. " ("
      .. #node.results
      .. ")"
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

return M
