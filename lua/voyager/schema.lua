local Actions = require("voyager.lsp.actions")
local Locator = require("voyager.locator")

local M = {}

local function fail(message)
  error("schema v1: " .. message, 0)
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
    then
      fail(path .. " project locator path is not canonical")
    end
  elseif value.kind == "absolute" then
    reject_unknown(value, path, { kind = true, path = true })
    require_string(value.path, path .. ".path")
    if value.path:sub(1, 1) ~= "/" or value.path:find("\\", 1, true) or vim.fs.normalize(value.path) ~= value.path then
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

local function validate_location(value, path)
  require_object(value, path)
  reject_unknown(value, path, { locator = true, range = true, symbol = true, context = true })
  validate_locator(value.locator, path .. ".locator")
  validate_range(value.range, path .. ".range")
  require_string(value.symbol, path .. ".symbol")
  if value.context ~= nil then
    require_string(value.context, path .. ".context")
  end
end

local function validate_timestamp(value, path)
  require_string(value, path)
  if not value:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") then
    fail(path .. " must be a UTC RFC 3339 timestamp at second precision")
  end
end

function M.validate(document)
  require_object(document, "$")
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
  if document.schema_version ~= 1 then
    fail("$.schema_version must equal 1")
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
      reject_unknown(node, path, { id = true, kind = true, location = true, note = true, actions = true })
      validate_location(node.location, path .. ".location")
      if node.note ~= nil then
        require_string(node.note, path .. ".note")
      end
      require_array(node.actions, path .. ".actions")
      for index, action in ipairs(node.actions) do
        validate_node(action, "action", string.format("%s.actions[%d]", path, index))
      end
    else
      reject_unknown(node, path, {
        id = true,
        kind = true,
        method = true,
        label = true,
        collapsed = true,
        results = true,
      })
      require_string(node.method, path .. ".method")
      if not select(2, Actions.by_method(node.method)) then
        fail(path .. ".method is not supported")
      end
      require_string(node.label, path .. ".label")
      if type(node.collapsed) ~= "boolean" then
        fail(path .. ".collapsed must be a boolean")
      end
      require_array(node.results, path .. ".results")
      for index, location in ipairs(node.results) do
        validate_node(location, "location", string.format("%s.results[%d]", path, index))
      end
    end
  end

  validate_node(document.root, "location", "$.root")
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
  return vim.deepcopy(document)
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

local function encode_location(value, level)
  local fields = {
    { "locator", value.locator, encode_locator },
    { "range", value.range, encode_range },
    { "symbol", value.symbol },
  }
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
    table.insert(fields, { "actions", value.actions, encode_nodes })
    return object(fields, level)
  end
  return object({
    { "id", value.id },
    { "kind", value.kind },
    { "method", value.method },
    { "label", value.label },
    { "collapsed", value.collapsed },
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
