local Locator = require("voyager.locator")
local Actions = require("voyager.lsp.actions")

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
  self._parents = {}
  self._identity_index = {}
  local function visit(node, parent_id)
    assert(not self._index[node.id], "duplicate Voyager node ID: " .. node.id)
    self._index[node.id] = node
    self._parents[node.id] = parent_id
    if node.kind == "location" then
      local identity = Locator.location_key(node.location)
      if not self._identity_index[identity] then
        self._identity_index[identity] = node.id
      end
    end
    local children = node.kind == "location" and node.actions or node.results
    for _, child in ipairs(children) do
      visit(child, node.id)
    end
  end
  visit(self.root, nil)
end

function Flow:parent_id(node_id)
  return self._parents[node_id]
end

function M.new(opts)
  assert(type(opts) == "table", "Voyager flow options are required")
  assert(type(opts.now) == "function", "Voyager flow clock is required")
  assert(type(opts.next_id) == "function", "Voyager flow ID factory is required")
  local timestamp = opts.now()
  local root = location_node(opts.next_id("location"), clean_location(opts.root))
  root.visited = true
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
      deleted = {},
      current_node_id = true,
    },
  }, Flow)
  self:_reindex()
  return self
end

local function canonicalize_labels(node)
  if node.kind == "action" then
    local _, action = Actions.by_method(node.method)
    assert(action, "unknown Voyager action method: " .. tostring(node.method))
    node.label = action.label
    for _, result in ipairs(node.results) do
      canonicalize_labels(result)
    end
    return
  end
  for _, action in ipairs(node.actions) do
    canonicalize_labels(action)
  end
end

function M.from_document(document, opts)
  assert(type(document) == "table", "Voyager document is required")
  assert(type(opts) == "table", "Voyager flow load options are required")
  assert(type(opts.now) == "function", "Voyager flow clock is required")
  assert(type(opts.next_id) == "function", "Voyager flow ID factory is required")
  local self = vim.deepcopy(document)
  canonicalize_labels(self.root)
  self._now = opts.now
  self._next_id = opts.next_id
  self._dirty = false
  self._journal = {
    notes = {},
    metadata = {},
    collapsed = {},
    deleted = {},
    current_node_id = false,
  }
  setmetatable(self, Flow)
  self:_reindex()
  local current = self._index[self.current_node_id]
  if current and current.kind == "location" then
    current.visited = true
  end
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
  node.visited = true
  self.current_node_id = node_id
  self._journal.current_node_id = true
  self._dirty = true
  return true
end

function Flow:apply_symbol(node_id, symbol, symbol_kind)
  local node = self:location(node_id)
  if not node then
    return false
  end
  local changed = false
  local touched = self._journal.metadata[node_id] or {}
  -- The root's symbol participates in the flow identity (root_key, name,
  -- flow_id), so enrichment may only refine its kind, never rename it.
  if node.id ~= self.root.id and type(symbol) == "string" and symbol ~= "" and node.location.symbol ~= symbol then
    node.location.symbol = symbol
    touched.symbol = true
    changed = true
  end
  if type(symbol_kind) == "string" and symbol_kind ~= "" and node.location.symbol_kind ~= symbol_kind then
    node.location.symbol_kind = symbol_kind
    touched.symbol = true
    changed = true
  end
  if changed then
    self._journal.metadata[node_id] = touched
    self._dirty = true
  end
  return changed
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

function Flow:mark_saved(document)
  local copy = vim.deepcopy(document)
  canonicalize_labels(copy.root)
  for _, key in ipairs({
    "schema_version",
    "position_encoding",
    "revision",
    "flow_id",
    "name",
    "root_key",
    "created_at",
    "updated_at",
    "current_node_id",
    "root",
  }) do
    self[key] = copy[key]
  end
  self._dirty = false
  self._journal = {
    notes = {},
    metadata = {},
    collapsed = {},
    deleted = {},
    current_node_id = false,
  }
  self:_reindex()
end

function Flow:_location_path(node_id)
  local found
  local function visit(location, trail)
    table.insert(trail, location)
    if location.id == node_id then
      found = vim.list_slice(trail)
    end
    for _, action in ipairs(location.actions) do
      for _, result in ipairs(action.results) do
        if found then
          break
        end
        visit(result, trail)
      end
    end
    table.remove(trail)
  end
  visit(self.root, {})
  return found or {}
end

function Flow:path_ids(node_id)
  local ids = {}
  for _, location in ipairs(self:_location_path(node_id)) do
    table.insert(ids, location.id)
  end
  return ids
end

local function collect_subtree_ids(node, ids)
  ids[node.id] = true
  local children = node.kind == "location" and node.actions or node.results
  for _, child in ipairs(children) do
    collect_subtree_ids(child, ids)
  end
  return ids
end

local function remove_child(list, node_id)
  for index, child in ipairs(list) do
    if child.id == node_id then
      table.remove(list, index)
      return true
    end
  end
  return false
end

function Flow:delete(node_id)
  local node = self:find(node_id)
  if not node or node.id == self.root.id then
    return false
  end
  local parent = assert(self:find(self._parents[node_id]), "Voyager delete target has no parent")

  local deleted_key
  local surviving_location_id
  if node.kind == "action" then
    assert(remove_child(parent.actions, node_id))
    deleted_key = node.method
    surviving_location_id = parent.id
  else
    assert(remove_child(parent.results, node_id))
    deleted_key = Locator.location_key(node.location)
    surviving_location_id = assert(self._parents[parent.id], "Voyager result has no owning location")
  end

  -- The deletion journal is keyed by the surviving parent's ID so a later
  -- save-merge can skip re-importing the branch from the on-disk document.
  local deleted = self._journal.deleted[parent.id] or {}
  deleted[deleted_key] = true
  self._journal.deleted[parent.id] = deleted

  local subtree = collect_subtree_ids(node, {})
  if subtree[self.current_node_id] then
    self.current_node_id = surviving_location_id
    self._journal.current_node_id = true
  end

  self._dirty = true
  self:_reindex()
  return true
end

function Flow:set_all_collapsed(collapsed)
  local changed = false
  for _, node in ipairs(self:dfs()) do
    if node.kind == "action" and node.collapsed ~= collapsed then
      node.collapsed = collapsed
      self._journal.collapsed[node.id] = collapsed
      changed = true
    end
  end
  if changed then
    self._dirty = true
  end
  return changed
end

function Flow:_commit_direct(input)
  local origin = self:location(input.origin_node_id)
  assert(origin, "Voyager navigation origin must be a location: " .. tostring(input.origin_node_id))
  assert(type(input.method) == "string" and input.method ~= "", "Voyager navigation method is required")
  assert(type(input.label) == "string" and input.label ~= "", "Voyager navigation label is required")

  local action
  for _, candidate in ipairs(origin.actions) do
    if candidate.method == input.method then
      action = candidate
      break
    end
  end

  local results_by_identity = {}
  if action then
    for _, result in ipairs(action.results) do
      results_by_identity[Locator.location_key(result.location)] = result
    end
  end

  -- A destination that is already recorded anywhere in the flow is the same
  -- place reached along another route; it maps to the existing node instead
  -- of growing a duplicate branch. The action's own results stay in the
  -- fresh list so their display metadata still refreshes below.
  local node_id_by_identity = {}
  local fresh = {}
  for _, location in ipairs(input.locations or {}) do
    local identity = location.identity or Locator.location_key(location)
    local existing_id = self._identity_index[identity]
    if existing_id and not results_by_identity[identity] then
      node_id_by_identity[identity] = existing_id
    else
      table.insert(fresh, location)
    end
  end

  local changed = false
  if not action and #fresh == 0 and #(input.locations or {}) > 0 then
    return {
      effective_origin_id = origin.id,
      action_id = nil,
      node_id_by_identity = node_id_by_identity,
      changed = false,
    }
  end
  if not action then
    action = action_node(self._next_id("action"), input.method, input.label)
    table.insert(origin.actions, action)
    self._index[action.id] = action
    self._parents[action.id] = origin.id
    changed = true
  end

  for _, location in ipairs(fresh) do
    local identity = location.identity or Locator.location_key(location)
    local result = results_by_identity[identity]
    if not result then
      result = location_node(self._next_id("location"), clean_location(location))
      table.insert(action.results, result)
      self._index[result.id] = result
      self._parents[result.id] = action.id
      self._identity_index[identity] = self._identity_index[identity] or result.id
      results_by_identity[identity] = result
      self._journal.metadata[result.id] = { symbol = true }
      if location.context ~= nil and location.context ~= "" then
        self._journal.metadata[result.id].context = true
      end
      changed = true
    else
      local touched = self._journal.metadata[result.id] or {}
      if type(location.symbol) == "string" and location.symbol ~= "" and result.location.symbol ~= location.symbol then
        result.location.symbol = location.symbol
        touched.symbol = true
        changed = true
      end
      if
        type(location.context) == "string"
        and location.context ~= ""
        and result.location.context ~= location.context
      then
        result.location.context = location.context
        touched.context = true
        changed = true
      end
      if next(touched) then
        self._journal.metadata[result.id] = touched
      end
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

local function collect_ids(node, ids)
  ids[node.id] = true
  local children = node.kind == "location" and node.actions or node.results
  for _, child in ipairs(children) do
    collect_ids(child, ids)
  end
end

local function root_identity_matches(latest, active)
  return Locator.location_key(latest.location) == Locator.location_key(active.location)
    and latest.location.symbol == active.location.symbol
end

function M.merge(latest_document, active_flow, active_journal, next_id)
  assert(type(latest_document) == "table", "Voyager latest document is required")
  assert(type(active_flow) == "table", "Voyager active flow is required")
  assert(type(active_journal) == "table", "Voyager active journal is required")
  assert(type(next_id) == "function", "Voyager merge ID factory is required")
  if not root_identity_matches(latest_document.root, active_flow.root) then
    error("Voyager merge requires identical root identity", 0)
  end

  local used_ids = {}
  collect_ids(active_flow.root, used_ids)
  local latest_to_merged = {}

  local function import_node(node)
    local copy = vim.deepcopy(node)
    local old_id = copy.id
    if used_ids[copy.id] then
      copy.id = next_id(copy.kind)
    end
    while used_ids[copy.id] do
      copy.id = next_id(copy.kind)
    end
    used_ids[copy.id] = true
    latest_to_merged[old_id] = copy.id
    local children = copy.kind == "location" and copy.actions or copy.results
    for index, child in ipairs(children) do
      children[index] = import_node(child)
    end
    return copy
  end

  local merge_location
  local merge_action

  local deleted_journal = active_journal.deleted or {}
  local function was_deleted(active_parent_id, key)
    local deleted = deleted_journal[active_parent_id]
    return deleted ~= nil and deleted[key] == true
  end

  local function merge_action_children(latest_actions, active_actions, active_location_id)
    local result = {}
    local active_by_method = {}
    local matched = {}
    for _, action in ipairs(active_actions) do
      active_by_method[action.method] = action
    end
    for _, latest_action in ipairs(latest_actions) do
      local active_action = active_by_method[latest_action.method]
      if active_action then
        matched[active_action] = true
        table.insert(result, merge_action(latest_action, active_action))
      elseif not was_deleted(active_location_id, latest_action.method) then
        table.insert(result, import_node(latest_action))
      end
    end
    for _, active_action in ipairs(active_actions) do
      if not matched[active_action] then
        table.insert(result, vim.deepcopy(active_action))
      end
    end
    return result
  end

  local function merge_result_children(latest_results, active_results, active_action_id)
    local result = {}
    local active_by_identity = {}
    local matched = {}
    for _, location in ipairs(active_results) do
      active_by_identity[Locator.location_key(location.location)] = location
    end
    for _, latest_location in ipairs(latest_results) do
      local identity = Locator.location_key(latest_location.location)
      local active_location = active_by_identity[identity]
      if active_location then
        matched[active_location] = true
        table.insert(result, merge_location(latest_location, active_location))
      elseif not was_deleted(active_action_id, identity) then
        table.insert(result, import_node(latest_location))
      end
    end
    for _, active_location in ipairs(active_results) do
      if not matched[active_location] then
        table.insert(result, vim.deepcopy(active_location))
      end
    end
    return result
  end

  merge_location = function(latest, active)
    latest_to_merged[latest.id] = active.id
    local merged = vim.deepcopy(active)
    local note_touch = active_journal.notes[active.id]
    if note_touch then
      if note_touch.note == vim.NIL then
        merged.note = nil
      else
        merged.note = note_touch.note
      end
    else
      merged.note = latest.note
    end
    local metadata_touch = active_journal.metadata[active.id] or {}
    if metadata_touch.symbol ~= true then
      merged.location.symbol = latest.location.symbol
      merged.location.symbol_kind = latest.location.symbol_kind
    end
    if metadata_touch.context ~= true then
      merged.location.context = latest.location.context
    end
    -- A node visited in either revision stays visited.
    merged.visited = (active.visited or latest.visited) and true or nil
    merged.actions = merge_action_children(latest.actions, active.actions, active.id)
    return merged
  end

  merge_action = function(latest, active)
    latest_to_merged[latest.id] = active.id
    local merged = vim.deepcopy(active)
    if active_journal.collapsed[active.id] == nil then
      merged.collapsed = latest.collapsed
    end
    merged.results = merge_result_children(latest.results, active.results, active.id)
    return merged
  end

  local root = merge_location(latest_document.root, active_flow.root)
  canonicalize_labels(root)

  local merged = vim.deepcopy(latest_document)
  merged.root = root
  merged.schema_version = 1
  merged.position_encoding = "utf-8"
  merged.revision = latest_document.revision + 1
  merged.created_at = latest_document.created_at
  merged.root_key = active_flow.root_key
  merged.name = Locator.flow_name(root.location)
  local hash_suffix = assert(active_flow.flow_id:match("%-([0-9a-f]+)$"))
  merged.flow_id = Locator.flow_id(root.location, #hash_suffix)

  if active_journal.current_node_id then
    merged.current_node_id = active_flow.current_node_id
  else
    merged.current_node_id = latest_to_merged[latest_document.current_node_id] or active_flow.current_node_id
  end
  return merged
end

return M
