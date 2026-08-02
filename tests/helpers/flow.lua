local Flow = require("voyager.flow")
local Locator = require("voyager.locator")

local M = {}

function M.identity(path, line)
  return string.format('["project","%s",%d,0,%d,4]', path, line, line)
end

function M.location(path, line, symbol, context)
  return {
    locator = { kind = "project", path = path },
    range = {
      start = { line = line, character = 0 },
      ["end"] = { line = line, character = 4 },
    },
    symbol = symbol or "symbol",
    context = context,
    identity = M.identity(path, line),
  }
end

function M.factories()
  local counter = 0
  return function()
    return "2026-08-01T18:25:43Z"
  end, function(kind)
    counter = counter + 1
    local prefix = kind == "location" and "loc" or "action"
    return string.format("%s-%032x", prefix, counter)
  end
end

function M.document()
  local root_location = M.location("lua/main.lua", 0, "main")
  root_location.identity = nil
  local root_key = Locator.root_key(root_location)
  return {
    schema_version = 1,
    position_encoding = "utf-8",
    revision = 3,
    flow_id = Locator.flow_id(root_location, 8),
    name = Locator.flow_name(root_location),
    root_key = root_key,
    created_at = "2026-08-01T18:25:43Z",
    updated_at = "2026-08-01T18:41:02Z",
    current_node_id = "loc-00000000000000000000000000000001",
    root = {
      id = "loc-00000000000000000000000000000001",
      kind = "location",
      location = root_location,
      note = nil,
      actions = {},
    },
  }
end

function M.new_flow()
  local now, next_id = M.factories()
  local root = M.location("lua/main.lua", 0, "main")
  root.identity = nil
  local root_key = Locator.root_key(root)
  return Flow.new({
    root = root,
    name = Locator.flow_name(root),
    flow_id = Locator.flow_id(root, 8),
    root_key = root_key,
    now = now,
    next_id = next_id,
  })
end

function M.branched_flow()
  local flow = M.new_flow()
  local mysql = M.location("lua/mysql.lua", 2, "MysqlStore.save")
  local memory = M.location("lua/memory.lua", 3, "MemoryStore.save")
  local commit = flow:commit_navigation({
    origin_node_id = flow.root.id,
    method = "textDocument/implementation",
    label = "implementations",
    locations = { mysql, memory },
  })
  flow:set_note(commit.node_id_by_identity[mysql.identity], "important for auth")
  return flow
end

return M
