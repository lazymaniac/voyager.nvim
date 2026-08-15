local Actions = require("voyager.lsp.actions")
local Locator = require("voyager.locator")

local M = {}
local current_version = 2
local error_version = current_version

local function fail(message)
  error("schema v" .. error_version .. ": " .. message, 0)
end

local function with_error_version(version, callback)
  local previous = error_version
  error_version = version
  local ok, result = pcall(callback)
  error_version = previous
  if not ok then
    error(result, 0)
  end
  return result
end

local function require_object(value, path)
  if type(value) ~= "table" or vim.islist(value) then
    fail(path .. " must be an object")
  end
end

local function reject_unknown(value, path, allowed)
  for key in pairs(value) do
    if allowed[key] == nil then
      fail("unknown key " .. path .. "." .. tostring(key))
    end
  end
end

local function require_string(value, path)
  if type(value) ~= "string" or value == "" then
    fail(path .. " must be a non-empty string")
  end
end

local function require_integer(value, path, minimum)
  if type(value) ~= "number" or value % 1 ~= 0 or value < minimum then
    fail(path .. " must be an integer of at least " .. minimum)
  end
end

local function require_array(value, path)
  if type(value) ~= "table" or not vim.islist(value) then
    fail(path .. " must be an array")
  end
end

local function validate_id(value, kind, path)
  require_string(value, path)
  local prefix = kind == "location" and "loc-" or "action-"
  local suffix = value:sub(#prefix + 1)
  if value:sub(1, #prefix) ~= prefix or #suffix ~= 32 or not suffix:match("^[0-9a-f]+$") then
    fail(path .. " is not a canonical " .. kind .. " ID")
  end
end

local function validate_position(value, path)
  require_object(value, path)
  reject_unknown(value, path, { line = true, character = true })
  require_integer(value.line, path .. ".line", 0)
  require_integer(value.character, path .. ".character", 0)
end

local function validate_range(value, path)
  require_object(value, path)
  reject_unknown(value, path, { start = true, ["end"] = true })
  validate_position(value.start, path .. ".start")
  validate_position(value["end"], path .. ".end")
  local start = value.start
  local finish = value["end"]
  if finish.line < start.line or (finish.line == start.line and finish.character < start.character) then
    fail(path .. " end precedes start")
  end
end

local function validate_locator(value, path)
  require_object(value, path)
  require_string(value.kind, path .. ".kind")
  if value.kind == "project" then
    reject_unknown(value, path, { kind = true, path = true })
    require_string(value.path, path .. ".path")
    if
      value.path:sub(1, 1) == "/"
      or value.path:find("\\", 1, true)
      or value.path == "."
      or value.path:match("^%.%./")
      or value.path:match("/%.%./")
      or value.path:match("/%.%.$")
      or value.path:match("^%./")
      or value.path:match("/%./")
      or vim.fs.normalize("./" .. value.path, { expand_env = false }) ~= value.path
    then
      fail(path .. " project locator path is not canonical")
    end
  elseif value.kind == "absolute" then
    reject_unknown(value, path, { kind = true, path = true })
    require_string(value.path, path .. ".path")
    if
      value.path:sub(1, 1) ~= "/"
      or value.path:find("\\", 1, true)
      or vim.fs.normalize(value.path, { expand_env = false }) ~= value.path
    then
      fail(path .. " absolute locator path is not canonical")
    end
  elseif value.kind == "uri" then
    reject_unknown(value, path, { kind = true, uri = true })
    require_string(value.uri, path .. ".uri")
    if not value.uri:match("^[A-Za-z][A-Za-z0-9+.-]*:") or value.uri:sub(1, 5):lower() == "file:" then
      fail(path .. " URI locator is invalid")
    end
  else
    fail(path .. ".kind is not a supported locator kind")
  end
end

local function validate_query_anchor(value, path)
  require_object(value, path)
  reject_unknown(value, path, { locator = true, range = true, line_text = true })
  validate_locator(value.locator, path .. ".locator")
  validate_range(value.range, path .. ".range")
  require_string(value.line_text, path .. ".line_text")
end

local function validate_location(value, path, version)
  require_object(value, path)
  local allowed = {
    locator = true,
    range = true,
    symbol = true,
    symbol_kind = true,
    context = true,
  }
  if version >= 2 then
    allowed.query_anchor = true
  end
  reject_unknown(value, path, allowed)
  validate_locator(value.locator, path .. ".locator")
  validate_range(value.range, path .. ".range")
  if value.query_anchor ~= nil then
    validate_query_anchor(value.query_anchor, path .. ".query_anchor")
  end
  require_string(value.symbol, path .. ".symbol")
  if value.symbol_kind ~= nil then
    require_string(value.symbol_kind, path .. ".symbol_kind")
  end
  if value.context ~= nil then
    require_string(value.context, path .. ".context")
  end
end

local function validate_timestamp(value, path)
  require_string(value, path)
  local year, month, day, hour, minute, second = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
  if not year then
    fail(path .. " must be a UTC RFC 3339 timestamp at second precision")
  end

  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
  local leap_year = year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
  local month_days = { 31, leap_year and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if month < 1 or month > 12 or day < 1 or day > month_days[month] or hour > 23 or minute > 59 or second > 60 then
    fail(path .. " must be a UTC RFC 3339 timestamp at second precision")
  end
end

local function validate_document(document, version)
  require_object(document, "$")
  document = vim.deepcopy(document)
  reject_unknown(document, "$", {
    schema_version = true,
    position_encoding = true,
    revision = true,
    flow_id = true,
    name = true,
    root_key = true,
    created_at = true,
    updated_at = true,
    current_node_id = true,
    root = true,
  })
  if document.schema_version ~= version then
    fail("$.schema_version must equal " .. version)
  end
  if document.position_encoding ~= "utf-8" then
    fail("$.position_encoding must equal utf-8")
  end
  require_integer(document.revision, "$.revision", 1)
  require_string(document.flow_id, "$.flow_id")
  require_string(document.name, "$.name")
  require_string(document.root_key, "$.root_key")
  if #document.root_key ~= 64 or not document.root_key:match("^[0-9a-f]+$") then
    fail("$.root_key must be a 64-character lowercase SHA-256")
  end
  validate_timestamp(document.created_at, "$.created_at")
  validate_timestamp(document.updated_at, "$.updated_at")
  require_string(document.current_node_id, "$.current_node_id")

  local ids = {}
  local location_identities = {}
  local action_targets = {}
  local function validate_node(node, expected_kind, path)
    require_object(node, path)
    if node.kind ~= expected_kind then
      fail(path .. ".kind must be " .. expected_kind)
    end
    validate_id(node.id, expected_kind, path .. ".id")
    if ids[node.id] then
      fail(path .. ".id is a duplicate node ID")
    end
    ids[node.id] = expected_kind

    if expected_kind == "location" then
      reject_unknown(
        node,
        path,
        { id = true, kind = true, location = true, note = true, visited = true, actions = true }
      )
      validate_location(node.location, path .. ".location", version)
      local identity = Locator.location_key(node.location)
      if version >= 2 and location_identities[identity] then
        fail(path .. ".location duplicates location identity at " .. location_identities[identity])
      end
      if version >= 2 then
        location_identities[identity] = path .. ".location"
      end
      if node.note ~= nil then
        require_string(node.note, path .. ".note")
      end
      if node.visited ~= nil and type(node.visited) ~= "boolean" then
        fail(path .. ".visited must be a boolean")
      end
      require_array(node.actions, path .. ".actions")
      local methods = {}
      for index, action in ipairs(node.actions) do
        local child_path = string.format("%s.actions[%d]", path, index)
        validate_node(action, "action", child_path)
        if methods[action.method] then
          fail(child_path .. ".method duplicates a sibling action method")
        end
        methods[action.method] = true
      end
    else
      local allowed = {
        id = true,
        kind = true,
        method = true,
        label = true,
        collapsed = true,
        results = true,
      }
      if version >= 2 then
        allowed.target_ids = true
        allowed.query_status = true
      end
      reject_unknown(node, path, allowed)
      require_string(node.method, path .. ".method")
      local _, action_record = Actions.by_method(node.method)
      if not action_record or (version == 1 and action_record.storage == true) then
        fail(path .. ".method is not supported")
      end
      require_string(node.label, path .. ".label")
      if type(node.collapsed) ~= "boolean" then
        fail(path .. ".collapsed must be a boolean")
      end
      require_array(node.results, path .. ".results")
      local sibling_identities = {}
      for index, location in ipairs(node.results) do
        local child_path = string.format("%s.results[%d]", path, index)
        validate_node(location, "location", child_path)
        if version == 1 then
          local identity = Locator.location_key(location.location)
          if sibling_identities[identity] then
            fail(child_path .. ".location duplicates a sibling location identity")
          end
          sibling_identities[identity] = true
        end
      end
      if version >= 2 then
        require_array(node.target_ids, path .. ".target_ids")
        if node.query_status ~= "complete" and node.query_status ~= "partial" then
          fail(path .. ".query_status must equal complete or partial")
        end
        local targets = {}
        local seen_targets = {}
        for index, target_id in ipairs(node.target_ids) do
          local target_path = string.format("%s.target_ids[%d]", path, index)
          validate_id(target_id, "location", target_path)
          if seen_targets[target_id] then
            fail(target_path .. " duplicates an earlier target ID")
          end
          seen_targets[target_id] = true
          table.insert(targets, { id = target_id, path = target_path })
        end
        table.insert(action_targets, targets)
      end
    end
  end

  validate_node(document.root, "location", "$.root")
  for _, targets in ipairs(action_targets) do
    for _, target in ipairs(targets) do
      if ids[target.id] == nil then
        fail(target.path .. " references a missing location")
      end
      if ids[target.id] ~= "location" then
        fail(target.path .. " must reference a location node")
      end
    end
  end
  if ids[document.current_node_id] ~= "location" then
    fail("$.current_node_id must reference a location node")
  end

  local expected_root_key = Locator.root_key(document.root.location)
  if document.root_key ~= expected_root_key then
    fail("$.root_key does not match root identity")
  end
  local expected_name = Locator.flow_name(document.root.location)
  if document.name ~= expected_name then
    fail("$.name does not match root identity")
  end
  local valid_flow_id = false
  for _, length in ipairs({ 8, 16, 64 }) do
    if document.flow_id == Locator.flow_id(document.root.location, length) then
      valid_flow_id = true
      break
    end
  end
  if not valid_flow_id then
    fail("$.flow_id does not match root identity")
  end
  return document
end

local function append_unique(values, value)
  for _, candidate in ipairs(values) do
    if candidate == value then
      return
    end
  end
  table.insert(values, value)
end

local function migrate_v1(document)
  local migrated = vim.deepcopy(document)
  local canonical_by_identity = {}
  local id_remap = {}
  local register_location
  local merge_action_into

  local function merge_location_metadata(existing, incoming)
    if existing.note == nil and incoming.note ~= nil then
      existing.note = incoming.note
    end
    if existing.location.symbol_kind == nil and incoming.location.symbol_kind ~= nil then
      existing.location.symbol_kind = incoming.location.symbol_kind
    end
    if existing.location.context == nil and incoming.location.context ~= nil then
      existing.location.context = incoming.location.context
    end
    if incoming.visited == true then
      existing.visited = true
    end
  end

  merge_action_into = function(owner, incoming)
    local action
    for _, candidate in ipairs(owner.actions) do
      if candidate.method == incoming.method then
        action = candidate
        break
      end
    end
    if not action then
      action = {
        id = incoming.id,
        kind = "action",
        method = incoming.method,
        label = incoming.label,
        collapsed = incoming.collapsed,
        target_ids = {},
        query_status = "complete",
        results = {},
      }
      table.insert(owner.actions, action)
    end

    for _, result in ipairs(incoming.results) do
      local canonical, is_new = register_location(result)
      append_unique(action.target_ids, canonical.id)
      if is_new then
        table.insert(action.results, canonical)
      end
    end
  end

  register_location = function(incoming)
    local identity = Locator.location_key(incoming.location)
    local existing = canonical_by_identity[identity]
    if existing then
      id_remap[incoming.id] = existing.id
      merge_location_metadata(existing, incoming)
      for _, action in ipairs(incoming.actions) do
        merge_action_into(existing, action)
      end
      return existing, false
    end

    local canonical = {
      id = incoming.id,
      kind = "location",
      location = vim.deepcopy(incoming.location),
      actions = {},
    }
    if incoming.note ~= nil then
      canonical.note = incoming.note
    end
    if incoming.visited == true then
      canonical.visited = true
    end
    canonical_by_identity[identity] = canonical
    id_remap[incoming.id] = canonical.id
    for _, action in ipairs(incoming.actions) do
      merge_action_into(canonical, action)
    end
    return canonical, true
  end

  migrated.root = register_location(document.root)
  migrated.current_node_id = id_remap[document.current_node_id]
  migrated.schema_version = current_version
  return migrated
end

function M.validate(document)
  local version = type(document) == "table" and document.schema_version or current_version
  if version == 1 then
    local legacy = with_error_version(1, function()
      return validate_document(document, 1)
    end)
    local migrated = migrate_v1(legacy)
    return with_error_version(current_version, function()
      return validate_document(migrated, current_version)
    end)
  end
  return with_error_version(current_version, function()
    return validate_document(document, current_version)
  end)
end

local function indent(level)
  return string.rep("  ", level)
end

local function object(fields, level)
  local lines = { "{" }
  for index, field in ipairs(fields) do
    local value = field[2]
    local encoded = field[3] and field[3](value, level + 1) or vim.json.encode(value)
    if index < #fields then
      encoded = encoded .. ","
    end
    table.insert(lines, indent(level + 1) .. vim.json.encode(field[1]) .. ": " .. encoded)
  end
  table.insert(lines, indent(level) .. "}")
  return table.concat(lines, "\n")
end

local function array(values, level, encoder)
  if #values == 0 then
    return "[]"
  end
  local lines = { "[" }
  for index, value in ipairs(values) do
    local encoded = encoder(value, level + 1)
    if index < #values then
      encoded = encoded .. ","
    end
    table.insert(lines, indent(level + 1) .. encoded)
  end
  table.insert(lines, indent(level) .. "]")
  return table.concat(lines, "\n")
end

local function encode_position(value, level)
  return object({ { "line", value.line }, { "character", value.character } }, level)
end

local function encode_range(value, level)
  return object({
    { "start", value.start, encode_position },
    { "end", value["end"], encode_position },
  }, level)
end

local function encode_locator(value, level)
  if value.kind == "uri" then
    return object({ { "kind", value.kind }, { "uri", value.uri } }, level)
  end
  return object({ { "kind", value.kind }, { "path", value.path } }, level)
end

local function encode_query_anchor(value, level)
  return object({
    { "locator", value.locator, encode_locator },
    { "range", value.range, encode_range },
    { "line_text", value.line_text },
  }, level)
end

local function encode_location(value, level)
  local fields = {
    { "locator", value.locator, encode_locator },
    { "range", value.range, encode_range },
  }
  if value.query_anchor ~= nil then
    table.insert(fields, { "query_anchor", value.query_anchor, encode_query_anchor })
  end
  table.insert(fields, { "symbol", value.symbol })
  if value.symbol_kind ~= nil then
    table.insert(fields, { "symbol_kind", value.symbol_kind })
  end
  if value.context ~= nil then
    table.insert(fields, { "context", value.context })
  end
  return object(fields, level)
end

local encode_node

local function encode_nodes(values, level)
  return array(values, level, encode_node)
end

encode_node = function(value, level)
  if value.kind == "location" then
    local fields = {
      { "id", value.id },
      { "kind", value.kind },
      { "location", value.location, encode_location },
    }
    if value.note ~= nil then
      table.insert(fields, { "note", value.note })
    end
    if value.visited == true then
      table.insert(fields, { "visited", value.visited })
    end
    table.insert(fields, { "actions", value.actions, encode_nodes })
    return object(fields, level)
  end
  return object({
    { "id", value.id },
    { "kind", value.kind },
    { "method", value.method },
    { "label", value.label },
    { "collapsed", value.collapsed },
    { "target_ids", value.target_ids },
    { "query_status", value.query_status },
    { "results", value.results, encode_nodes },
  }, level)
end

function M.encode(document)
  local value = M.validate(document)
  return object({
    { "schema_version", value.schema_version },
    { "position_encoding", value.position_encoding },
    { "revision", value.revision },
    { "flow_id", value.flow_id },
    { "name", value.name },
    { "root_key", value.root_key },
    { "created_at", value.created_at },
    { "updated_at", value.updated_at },
    { "current_node_id", value.current_node_id },
    { "root", value.root, encode_node },
  }, 0) .. "\n"
end

function M.decode(json_text)
  if type(json_text) ~= "string" then
    fail("JSON input must be a string")
  end
  local ok, document = pcall(vim.json.decode, json_text)
  if not ok then
    fail("invalid JSON: " .. tostring(document))
  end
  return M.validate(document)
end

return M
