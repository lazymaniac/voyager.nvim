local Locator = require("voyager.locator")

local M = {}
local Flow = {}
Flow.__index = Flow

local function location_node(id, location)
  return {
    id = id,
    kind = "location",
    location = vim.deepcopy(location),
    note = nil,
    actions = {},
  }
end

local function action_node(id, method, label)
  return {
    id = id,
    kind = "action",
    method = method,
    label = label,
    collapsed = false,
    results = {},
  }
end

local function clean_location(location)
  local copy = vim.deepcopy(location)
  copy.identity = nil
  return copy
end

function Flow:_reindex()
  self._index = {}
  local function visit(node)
    assert(not self._index[node.id], "duplicate Voyager node ID: " .. node.id)
    self._index[node.id] = node
    local children = node.kind == "location" and node.actions or node.results
    for _, child in ipairs(children) do
      visit(child)
    end
  end
  visit(self.root)
end

function M.new(opts)
  assert(type(opts) == "table", "Voyager flow options are required")
  assert(type(opts.now) == "function", "Voyager flow clock is required")
  assert(type(opts.next_id) == "function", "Voyager flow ID factory is required")
  local timestamp = opts.now()
  local root = location_node(opts.next_id("location"), clean_location(opts.root))
  local self = setmetatable({
    schema_version = 1,
    position_encoding = "utf-8",
    revision = 0,
    flow_id = opts.flow_id,
    name = opts.name,
    root_key = opts.root_key,
    created_at = timestamp,
    updated_at = timestamp,
    current_node_id = root.id,
    root = root,
    _now = opts.now,
    _next_id = opts.next_id,
    _dirty = false,
    _journal = {
      notes = {},
      metadata = { [root.id] = { symbol = true, context = true } },
      collapsed = {},
      current_node_id = true,
    },
  }, Flow)
  self:_reindex()
  return self
end

function Flow:find(node_id)
  return self._index[node_id]
end

function Flow:location(node_id)
  local node = self:find(node_id)
  return node and node.kind == "location" and node or nil
end

function Flow:dfs()
  local nodes = {}
  local function visit(node)
    table.insert(nodes, node)
    local children = node.kind == "location" and node.actions or node.results
    for _, child in ipairs(children) do
      visit(child)
    end
  end
  visit(self.root)
  return nodes
end

function Flow:set_current(node_id)
  local node = self:find(node_id)
  if not node then
    return false
  end
  assert(node.kind == "location", "Voyager current node must be a location: " .. node_id)
  if self.current_node_id == node_id then
    return false
  end
  self.current_node_id = node_id
  self._journal.current_node_id = true
  self._dirty = true
  return true
end

function Flow:set_note(node_id, note)
  local node = self:find(node_id)
  if not node then
    return false
  end
  assert(node.kind == "location", "Voyager note target must be a location: " .. node_id)
  assert(note == nil or type(note) == "string", "Voyager note must be a string or nil")
  if node.note == note then
    return false
  end
  node.note = note
  self._journal.notes[node_id] = { note = note == nil and vim.NIL or note }
  self._dirty = true
  return true
end

function Flow:toggle(node_id)
  local node = self:find(node_id)
  if not node then
    return false
  end
  assert(node.kind == "action", "Voyager toggle target must be an action: " .. node_id)
  node.collapsed = not node.collapsed
  self._journal.collapsed[node_id] = node.collapsed
  self._dirty = true
  return true
end

function Flow:is_dirty()
  return self._dirty
end

function Flow:journal()
  return vim.deepcopy(self._journal)
end

function Flow:_commit_direct(input)
  local origin = self:location(input.origin_node_id)
  assert(origin, "Voyager navigation origin must be a location: " .. tostring(input.origin_node_id))
  assert(type(input.method) == "string" and input.method ~= "", "Voyager navigation method is required")
  assert(type(input.label) == "string" and input.label ~= "", "Voyager navigation label is required")

  local changed = false
  local action
  for _, candidate in ipairs(origin.actions) do
    if candidate.method == input.method then
      action = candidate
      break
    end
  end
  if not action then
    action = action_node(self._next_id("action"), input.method, input.label)
    table.insert(origin.actions, action)
    self._index[action.id] = action
    changed = true
  end

  local results_by_identity = {}
  for _, result in ipairs(action.results) do
    results_by_identity[Locator.location_key(result.location)] = result
  end

  local node_id_by_identity = {}
  for _, location in ipairs(input.locations or {}) do
    local identity = location.identity or Locator.location_key(location)
    local result = results_by_identity[identity]
    if not result then
      result = location_node(self._next_id("location"), clean_location(location))
      table.insert(action.results, result)
      self._index[result.id] = result
      results_by_identity[identity] = result
      self._journal.metadata[result.id] = {
        symbol = true,
        context = location.context ~= nil and location.context ~= "",
      }
      changed = true
    end
    node_id_by_identity[identity] = result.id
  end

  if changed then
    self._dirty = true
  end
  return {
    effective_origin_id = origin.id,
    action_id = action.id,
    node_id_by_identity = node_id_by_identity,
    changed = changed,
  }
end

function Flow:commit_navigation(input)
  if not input.manual_location then
    return self:_commit_direct(input)
  end

  local staged = setmetatable(vim.deepcopy(self), Flow)
  staged:_reindex()
  local manual = staged:_commit_direct({
    origin_node_id = input.origin_node_id,
    method = "voyager/manual",
    label = "manual jump",
    locations = { input.manual_location },
  })
  local identity = input.manual_location.identity or Locator.location_key(input.manual_location)
  local effective_origin_id = assert(manual.node_id_by_identity[identity])
  local result = staged:_commit_direct({
    origin_node_id = effective_origin_id,
    method = input.method,
    label = input.label,
    locations = input.locations,
  })

  self.root = staged.root
  self.current_node_id = staged.current_node_id
  self._dirty = staged._dirty
  self._journal = staged._journal
  self:_reindex()
  result.effective_origin_id = effective_origin_id
  result.changed = manual.changed or result.changed
  return result
end

return M
