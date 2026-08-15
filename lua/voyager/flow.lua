local Locator = require("voyager.locator")
local Actions = require("voyager.lsp.actions")

local M = {}
local Flow = {}
Flow.__index = Flow

local query_statuses = {
  complete = true,
  partial = true,
}

local archive_method = "voyager/archive"

local function location_node(id, location)
  return {
    id = id,
    kind = "location",
    location = vim.deepcopy(location),
    note = nil,
    actions = {},
  }
end

local function action_node(id, method, label, query_status)
  return {
    id = id,
    kind = "action",
    method = method,
    label = label,
    collapsed = false,
    target_ids = {},
    query_status = query_status or "complete",
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
  local actions = {}
  local function visit(node, parent_id)
    assert(not self._index[node.id], "duplicate Voyager node ID: " .. node.id)
    self._index[node.id] = node
    self._parents[node.id] = parent_id
    if node.kind == "location" then
      local identity = Locator.location_key(node.location)
      assert(not self._identity_index[identity], "duplicate Voyager location identity: " .. identity)
      self._identity_index[identity] = node.id
    else
      table.insert(actions, node)
    end
    local children = node.kind == "location" and node.actions or node.results
    for _, child in ipairs(children) do
      visit(child, node.id)
    end
  end
  visit(self.root, nil)

  -- Documents written before relationship links were introduced implicitly
  -- targeted every location owned below an action. Normalize that legacy
  -- representation in memory, then enforce the same invariants as schema v2.
  for _, action in ipairs(actions) do
    if action.target_ids == nil then
      action.target_ids = vim.tbl_map(function(result)
        return result.id
      end, action.results)
    end
    action.query_status = action.query_status or "complete"
    assert(
      type(action.target_ids) == "table" and vim.islist(action.target_ids),
      "Voyager action targets must be a list"
    )
    assert(
      query_statuses[action.query_status],
      "Voyager action query status is invalid: " .. tostring(action.query_status)
    )
    local seen = {}
    for _, target_id in ipairs(action.target_ids) do
      assert(not seen[target_id], "duplicate Voyager action target ID: " .. tostring(target_id))
      seen[target_id] = true
      local target = self._index[target_id]
      assert(target and target.kind == "location", "dangling Voyager action target ID: " .. tostring(target_id))
    end
  end
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
    schema_version = 2,
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
      relationships = {},
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
    relationships = {},
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

function Flow:action_for(origin_id, method)
  local origin = self:location(origin_id)
  if not origin or type(method) ~= "string" then
    return nil
  end
  for _, action in ipairs(origin.actions) do
    if action.method == method then
      return action
    end
  end
end

function Flow:action_target_ids(action_or_id)
  local action = type(action_or_id) == "string" and self:find(action_or_id) or action_or_id
  if type(action) ~= "table" or action.kind ~= "action" then
    return {}
  end
  if action.target_ids == nil then
    return vim.tbl_map(function(result)
      return result.id
    end, action.results or {})
  end
  return vim.deepcopy(action.target_ids)
end

function Flow:_relationship_touch(action_id)
  self._journal.relationships = self._journal.relationships or {}
  local touch = self._journal.relationships[action_id]
  if not touch then
    touch = {}
    self._journal.relationships[action_id] = touch
  end
  return touch
end

function Flow:unlink_target(action_id, target_id)
  local action = self:find(action_id)
  if not action then
    return false
  end
  assert(action.kind == "action", "Voyager unlink origin must be an action: " .. tostring(action_id))
  if not self:location(target_id) then
    return false
  end

  local removed = false
  action.target_ids = vim.tbl_filter(function(candidate)
    if candidate == target_id then
      removed = true
      return false
    end
    return true
  end, action.target_ids or {})
  if not removed then
    return false
  end

  local touch = self:_relationship_touch(action.id)
  if touch.replace_targets ~= true then
    touch.removed_target_ids = touch.removed_target_ids or {}
    touch.removed_target_ids[target_id] = true
  end
  self._dirty = true
  return true
end

function Flow:delete_action_relation(action_id)
  local action = self:find(action_id)
  if not action then
    return false
  end
  assert(action.kind == "action", "Voyager relation delete target must be an action: " .. tostring(action_id))
  if action.method == archive_method then
    return false
  end

  local parent = assert(self:location(self._parents[action.id]), "Voyager action has no owning location")
  local removed = false
  for index, candidate in ipairs(parent.actions) do
    if candidate.id == action.id then
      table.remove(parent.actions, index)
      removed = true
      break
    end
  end
  assert(removed)

  if #(action.results or {}) > 0 then
    local storage_action
    for _, candidate in ipairs(parent.actions) do
      if candidate.method == archive_method then
        storage_action = candidate
        break
      end
    end
    if not storage_action then
      local _, archive = Actions.by_method(archive_method)
      storage_action = action_node(self._next_id("action"), archive_method, assert(archive).label, "complete")
      storage_action.collapsed = true
      table.insert(parent.actions, storage_action)
    end
    for _, result in ipairs(action.results) do
      table.insert(storage_action.results, result)
    end
    action.results = {}
  end

  local deleted = self._journal.deleted[parent.id] or {}
  deleted[action.method] = true
  self._journal.deleted[parent.id] = deleted
  self._dirty = true
  self:_reindex()
  return true
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

function Flow:apply_symbol(node_id, symbol, symbol_kind, query_anchor)
  local node = self:location(node_id)
  if not node then
    return false
  end
  if node.id ~= self.root.id and node.location.query_anchor ~= nil then
    return false
  end
  local changed = false
  local touched = self._journal.metadata[node_id] or {}
  -- A semantic display name and its LSP subject anchor are one update. The
  -- root participates in flow identity, while an existing protocol/semantic
  -- anchor is already authoritative and is left untouched.
  if node.id ~= self.root.id and type(symbol) == "string" and symbol ~= "" and type(query_anchor) == "table" then
    if node.location.symbol ~= symbol then
      node.location.symbol = symbol
      touched.symbol = true
      changed = true
    end
    if not vim.deep_equal(node.location.query_anchor, query_anchor) then
      node.location.query_anchor = vim.deepcopy(query_anchor)
      touched.query_anchor = true
      touched.symbol = true
      changed = true
    end
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

function Flow:set_collapsed(node_id, collapsed)
  assert(type(collapsed) == "boolean", "Voyager collapsed state must be a boolean")
  local node = self:find(node_id)
  if not node then
    return false
  end
  assert(node.kind == "action", "Voyager toggle target must be an action: " .. node_id)
  if node.collapsed == collapsed then
    return false
  end
  node.collapsed = collapsed
  self._journal.collapsed[node_id] = node.collapsed
  self._dirty = true
  return true
end

function Flow:toggle(node_id)
  local node = self:find(node_id)
  if not node then
    return false
  end
  assert(node.kind == "action", "Voyager toggle target must be an action: " .. node_id)
  return self:set_collapsed(node_id, not node.collapsed)
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
    relationships = {},
    current_node_id = false,
  }
  self:_reindex()
end

function Flow:_location_path(node_id)
  local found
  local visited = {}
  local function visit(location, trail)
    if visited[location.id] then
      return false
    end
    visited[location.id] = true
    table.insert(trail, location)
    if location.id == node_id then
      found = vim.list_slice(trail)
      return true
    end
    for _, action in ipairs(location.actions) do
      for _, target_id in ipairs(action.target_ids or {}) do
        local target = self:location(target_id)
        if target and visit(target, trail) then
          return true
        end
      end
    end
    table.remove(trail)
    return false
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

local function remove_action_targets(node, removed_ids)
  if node.kind == "action" then
    node.target_ids = vim.tbl_filter(function(target_id)
      return not removed_ids[target_id]
    end, node.target_ids or {})
  end
  local children = node.kind == "location" and node.actions or node.results
  for _, child in ipairs(children) do
    remove_action_targets(child, removed_ids)
  end
end

function Flow:delete(node_id)
  local node = self:find(node_id)
  if not node or node.id == self.root.id then
    return false
  end
  local parent = assert(self:find(self._parents[node_id]), "Voyager delete target has no parent")

  local deleted_parent_id = parent.id
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
    if parent.method == archive_method and #parent.results == 0 then
      local archive_owner = assert(self:location(surviving_location_id), "Voyager archive has no owning location")
      assert(remove_child(archive_owner.actions, parent.id))
      deleted_parent_id = archive_owner.id
      deleted_key = archive_method
    end
  end

  -- The deletion journal is keyed by the surviving parent's ID so a later
  -- save-merge can skip re-importing the branch from the on-disk document.
  local deleted = self._journal.deleted[deleted_parent_id] or {}
  deleted[deleted_key] = true
  self._journal.deleted[deleted_parent_id] = deleted

  local subtree = collect_subtree_ids(node, {})
  if subtree[self.current_node_id] then
    self.current_node_id = surviving_location_id
    self._journal.current_node_id = true
  end

  -- Relationship links can point across ownership branches. Once their
  -- canonical storage node disappears, remove every surviving reference before
  -- rebuilding the indexes so no action can retain a dangling target.
  remove_action_targets(self.root, subtree)

  self._dirty = true
  self:_reindex()
  return true
end

function Flow:set_all_collapsed(collapsed)
  local changed = false
  for _, node in ipairs(self:dfs()) do
    if node.kind == "action" and node.method ~= archive_method and node.collapsed ~= collapsed then
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
  local query_status = input.query_status or "complete"
  assert(query_statuses[query_status], "Voyager navigation query status is invalid: " .. tostring(query_status))

  local action = self:action_for(origin.id, input.method)
  local changed = false
  if not action then
    action = action_node(self._next_id("action"), input.method, input.label, query_status)
    table.insert(origin.actions, action)
    self._index[action.id] = action
    self._parents[action.id] = origin.id
    changed = true
  elseif action.query_status ~= query_status then
    action.query_status = query_status
    changed = true
  end

  local relationship_touch = self:_relationship_touch(action.id)
  relationship_touch.query_status = true
  if input.replace_targets == true and query_status == "complete" then
    relationship_touch.replace_targets = true
    relationship_touch.removed_target_ids = nil
  end

  local target_ids = {}
  for _, target_id in ipairs(action.target_ids) do
    target_ids[target_id] = true
  end
  local returned_target_ids = {}
  local returned_targets = {}

  local function refresh_metadata(node, location)
    local touched = self._journal.metadata[node.id] or {}
    local metadata_changed = false
    -- The root symbol is part of the immutable flow identity. Other display
    -- metadata can still be refreshed when a relationship points back to it.
    local incoming_subject = type(location.query_anchor) == "table"
    if
      node.id ~= self.root.id
      and (node.location.query_anchor == nil or incoming_subject)
      and type(location.symbol) == "string"
      and location.symbol ~= ""
      and node.location.symbol ~= location.symbol
    then
      node.location.symbol = location.symbol
      touched.symbol = true
      metadata_changed = true
    end
    if
      type(location.symbol_kind) == "string"
      and location.symbol_kind ~= ""
      and node.location.symbol_kind ~= location.symbol_kind
    then
      node.location.symbol_kind = location.symbol_kind
      touched.symbol = true
      metadata_changed = true
    end
    if type(location.context) == "string" and location.context ~= "" and node.location.context ~= location.context then
      node.location.context = location.context
      touched.context = true
      metadata_changed = true
    end
    if incoming_subject and not vim.deep_equal(node.location.query_anchor, location.query_anchor) then
      node.location.query_anchor = vim.deepcopy(location.query_anchor)
      touched.query_anchor = true
      touched.symbol = true
      metadata_changed = true
    end
    if metadata_changed then
      self._journal.metadata[node.id] = touched
      changed = true
    end
  end

  -- Nested results continue to own newly discovered locations, while every
  -- returned identity is recorded as an ordered link to its canonical node.
  -- This preserves the storage tree but makes reverse and overlapping routes
  -- complete rather than silently dropping already-known destinations.
  local node_id_by_identity = {}
  for _, location in ipairs(input.locations or {}) do
    local identity = location.identity or Locator.location_key(location)
    local target_id = self._identity_index[identity]
    local target = target_id and self:location(target_id) or nil
    if not target then
      target = location_node(self._next_id("location"), clean_location(location))
      table.insert(action.results, target)
      self._index[target.id] = target
      self._parents[target.id] = action.id
      self._identity_index[identity] = target.id
      target_id = target.id
      self._journal.metadata[target.id] = { symbol = true }
      if location.context ~= nil and location.context ~= "" then
        self._journal.metadata[target.id].context = true
      end
      if type(location.query_anchor) == "table" then
        self._journal.metadata[target.id].query_anchor = true
      end
      changed = true
    else
      refresh_metadata(target, location)
    end
    if not returned_targets[target_id] then
      table.insert(returned_target_ids, target_id)
      returned_targets[target_id] = true
    end
    if relationship_touch.removed_target_ids then
      relationship_touch.removed_target_ids[target_id] = nil
      if next(relationship_touch.removed_target_ids) == nil then
        relationship_touch.removed_target_ids = nil
      end
    end
    if input.replace_targets ~= true and not target_ids[target_id] then
      table.insert(action.target_ids, target_id)
      target_ids[target_id] = true
      changed = true
    end
    node_id_by_identity[identity] = target_id
  end

  if input.replace_targets == true and not vim.deep_equal(action.target_ids, returned_target_ids) then
    action.target_ids = returned_target_ids
    changed = true
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
  local identity = input.manual_location.identity or Locator.location_key(input.manual_location)
  local effective_origin_id = staged._identity_index[identity]
  local manual_changed = false
  if not effective_origin_id then
    local manual = staged:_commit_direct({
      origin_node_id = input.origin_node_id,
      method = "voyager/manual",
      label = "manual jump",
      locations = { input.manual_location },
      query_status = "complete",
    })
    effective_origin_id = assert(manual.node_id_by_identity[identity])
    manual_changed = manual.changed
  end
  local result = staged:_commit_direct({
    origin_node_id = effective_origin_id,
    method = input.method,
    label = input.label,
    locations = input.locations,
    query_status = input.query_status,
    replace_targets = input.replace_targets,
  })

  self.root = staged.root
  self.current_node_id = staged.current_node_id
  self._dirty = staged._dirty
  self._journal = staged._journal
  self:_reindex()
  result.effective_origin_id = effective_origin_id
  result.changed = manual_changed or result.changed
  return result
end

local function collect_ids(node, ids)
  ids[node.id] = true
  local children = node.kind == "location" and node.actions or node.results
  for _, child in ipairs(children) do
    collect_ids(child, ids)
  end
end

local function normalize_relationship_fields(node)
  if node.kind == "action" then
    if node.target_ids == nil then
      node.target_ids = vim.tbl_map(function(result)
        return result.id
      end, node.results)
    end
    node.query_status = node.query_status or "complete"
  end
  local children = node.kind == "location" and node.actions or node.results
  for _, child in ipairs(children) do
    normalize_relationship_fields(child)
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

  latest_document = vim.deepcopy(latest_document)
  normalize_relationship_fields(latest_document.root)

  local used_ids = {}
  collect_ids(active_flow.root, used_ids)
  local latest_to_merged = {}
  local relationship_sources = {}
  local relationship_journal = active_journal.relationships or {}

  local function relationship_source(latest_targets, active_targets, active_action_id)
    local touch = active_action_id and relationship_journal[active_action_id] or nil
    return {
      latest = vim.deepcopy(latest_targets or {}),
      active = vim.deepcopy(active_targets or {}),
      authoritative = touch ~= nil and touch.replace_targets == true,
      removed_target_ids = vim.deepcopy((touch and touch.removed_target_ids) or {}),
      query_touched = touch ~= nil and touch.query_status == true,
      collapsed_touched = active_action_id ~= nil and active_journal.collapsed[active_action_id] ~= nil,
    }
  end

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
    if copy.kind == "action" then
      relationship_sources[copy] = relationship_source(node.target_ids, nil, nil)
    end
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
        if was_deleted(active_location_id, latest_action.method) then
          table.insert(result, vim.deepcopy(active_action))
        else
          table.insert(result, merge_action(latest_action, active_action))
        end
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
    if metadata_touch.query_anchor ~= true then
      merged.location.query_anchor = vim.deepcopy(latest.location.query_anchor or active.location.query_anchor)
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
    local relationship_touch = relationship_journal[active.id]
    if relationship_touch and relationship_touch.query_status == true then
      merged.query_status = active.query_status or "complete"
    elseif active.query_status == "partial" or latest.query_status == "partial" then
      merged.query_status = "partial"
    else
      merged.query_status = "complete"
    end
    relationship_sources[merged] = relationship_source(latest.target_ids, active.target_ids, active.id)
    merged.results = merge_result_children(latest.results, active.results, active.id)
    return merged
  end

  local root = merge_location(latest_document.root, active_flow.root)

  -- Active-only actions are copied directly by the structural merge. Give
  -- every action a source record before canonicalizing duplicate locations so
  -- relationship state can be combined without depending on storage ownership.
  local function ensure_relationship_sources(node)
    if node.kind == "action" and not relationship_sources[node] then
      relationship_sources[node] = relationship_source(nil, node.target_ids, node.id)
    end
    local children = node.kind == "location" and node.actions or node.results
    for _, child in ipairs(children) do
      ensure_relationship_sources(child)
    end
  end
  ensure_relationship_sources(root)

  -- Concurrent writers can discover one physical location through different
  -- actions. Coalesce those storage nodes globally, merge their nested actions,
  -- and retain an ID map for relationship/current-node remapping below.
  local canonical_by_identity = {}
  local location_id_remap = {}
  local register_location
  local process_action
  local merge_action_into

  local function append_values(target, values)
    for _, value in ipairs(values or {}) do
      table.insert(target, value)
    end
  end

  local function merge_relationship_sources(existing, incoming)
    local left = assert(relationship_sources[existing], "Voyager merged action has no relationship source")
    local right = assert(relationship_sources[incoming], "Voyager incoming action has no relationship source")
    if right.query_touched and not left.query_touched then
      existing.query_status = incoming.query_status
    elseif not left.query_touched and not right.query_touched then
      if existing.query_status == "partial" or incoming.query_status == "partial" then
        existing.query_status = "partial"
      end
    end
    if right.collapsed_touched and not left.collapsed_touched then
      existing.collapsed = incoming.collapsed
    end
    append_values(left.latest, right.latest)
    append_values(left.active, right.active)
    for target_id in pairs(right.removed_target_ids or {}) do
      left.removed_target_ids[target_id] = true
    end
    left.authoritative = left.authoritative or right.authoritative
    left.query_touched = left.query_touched or right.query_touched
    left.collapsed_touched = left.collapsed_touched or right.collapsed_touched
    relationship_sources[incoming] = nil
  end

  local function merge_location_fields(existing, incoming)
    local existing_note_touch = active_journal.notes[existing.id]
    local incoming_note_touch = active_journal.notes[incoming.id]
    if incoming_note_touch and not existing_note_touch then
      existing.note = incoming.note
    elseif existing.note == nil and incoming.note ~= nil then
      existing.note = incoming.note
    end

    local existing_metadata_touch = active_journal.metadata[existing.id] or {}
    local incoming_metadata_touch = active_journal.metadata[incoming.id] or {}
    if incoming_metadata_touch.symbol == true and existing_metadata_touch.symbol ~= true then
      existing.location.symbol = incoming.location.symbol
      existing.location.symbol_kind = incoming.location.symbol_kind
    elseif existing.location.symbol_kind == nil and incoming.location.symbol_kind ~= nil then
      existing.location.symbol_kind = incoming.location.symbol_kind
    end
    if incoming_metadata_touch.context == true and existing_metadata_touch.context ~= true then
      existing.location.context = incoming.location.context
    elseif existing.location.context == nil and incoming.location.context ~= nil then
      existing.location.context = incoming.location.context
    end
    if incoming_metadata_touch.query_anchor == true and existing_metadata_touch.query_anchor ~= true then
      existing.location.query_anchor = vim.deepcopy(incoming.location.query_anchor)
    elseif existing.location.query_anchor == nil and incoming.location.query_anchor ~= nil then
      existing.location.query_anchor = vim.deepcopy(incoming.location.query_anchor)
    end
    existing.visited = (existing.visited or incoming.visited) and true or nil
  end

  process_action = function(action)
    local original_results = action.results or {}
    action.results = {}
    for _, child in ipairs(original_results) do
      local canonical, is_new = register_location(child)
      if is_new then
        table.insert(action.results, canonical)
      end
    end
  end

  merge_action_into = function(location, incoming)
    local existing
    for _, action in ipairs(location.actions) do
      if action.method == incoming.method then
        existing = action
        break
      end
    end
    if not existing then
      table.insert(location.actions, incoming)
      process_action(incoming)
      return
    end

    merge_relationship_sources(existing, incoming)
    for _, child in ipairs(incoming.results or {}) do
      local canonical, is_new = register_location(child)
      if is_new then
        table.insert(existing.results, canonical)
      end
    end
  end

  local function process_location(location)
    local original_actions = location.actions or {}
    location.actions = {}
    for _, action in ipairs(original_actions) do
      merge_action_into(location, action)
    end
  end

  register_location = function(location)
    local identity = Locator.location_key(location.location)
    local existing = canonical_by_identity[identity]
    if not existing then
      canonical_by_identity[identity] = location
      process_location(location)
      return location, true
    end
    if existing == location then
      return existing, false
    end

    location_id_remap[location.id] = existing.id
    merge_location_fields(existing, location)
    for _, action in ipairs(location.actions or {}) do
      merge_action_into(existing, action)
    end
    return existing, false
  end

  register_location(root)
  canonicalize_labels(root)

  local function map_latest_location_ids(node)
    if node.kind == "location" then
      local canonical = canonical_by_identity[Locator.location_key(node.location)]
      if canonical then
        latest_to_merged[node.id] = canonical.id
      end
    end
    local children = node.kind == "location" and node.actions or node.results
    for _, child in ipairs(children) do
      map_latest_location_ids(child)
    end
  end
  map_latest_location_ids(latest_document.root)

  local function canonical_location_id(id)
    local seen = {}
    while location_id_remap[id] and not seen[id] do
      seen[id] = true
      id = location_id_remap[id]
    end
    return id
  end

  local location_ids = {}
  local function collect_locations(node)
    if node.kind == "location" then
      location_ids[node.id] = true
    end
    local children = node.kind == "location" and node.actions or node.results
    for _, child in ipairs(children) do
      collect_locations(child)
    end
  end
  collect_locations(root)

  -- Saved nodes may be remapped for ID collisions or global identity
  -- canonicalization. Authoritative complete refreshes retain the active order
  -- exactly; additive/partial changes union disk then active links. Explicit
  -- edge removals filter either form without deleting canonical storage.
  local function resolve_relationships(node)
    if node.kind == "action" then
      local source = relationship_sources[node]
      local target_ids = {}
      local seen = {}
      local removed = {}
      for target_id in pairs((source and source.removed_target_ids) or {}) do
        removed[canonical_location_id(target_id)] = true
      end
      local function append(target_id)
        target_id = canonical_location_id(target_id)
        if location_ids[target_id] and not removed[target_id] and not seen[target_id] then
          table.insert(target_ids, target_id)
          seen[target_id] = true
        end
      end
      if source then
        if not source.authoritative then
          for _, latest_id in ipairs(source.latest) do
            append(latest_to_merged[latest_id])
          end
        end
        for _, active_id in ipairs(source.active) do
          append(active_id)
        end
      else
        for _, target_id in ipairs(node.target_ids or {}) do
          append(target_id)
        end
      end
      node.target_ids = target_ids
      node.query_status = node.query_status or "complete"
    end
    local children = node.kind == "location" and node.actions or node.results
    for _, child in ipairs(children) do
      resolve_relationships(child)
    end
  end
  resolve_relationships(root)

  local merged = vim.deepcopy(latest_document)
  merged.root = root
  merged.schema_version = 2
  merged.position_encoding = "utf-8"
  merged.revision = latest_document.revision + 1
  merged.created_at = latest_document.created_at
  merged.root_key = active_flow.root_key
  merged.name = Locator.flow_name(root.location)
  local hash_suffix = assert(active_flow.flow_id:match("%-([0-9a-f]+)$"))
  merged.flow_id = Locator.flow_id(root.location, #hash_suffix)

  if active_journal.current_node_id then
    merged.current_node_id = canonical_location_id(active_flow.current_node_id)
  else
    merged.current_node_id =
      canonical_location_id(latest_to_merged[latest_document.current_node_id] or active_flow.current_node_id)
  end
  return merged
end

return M
