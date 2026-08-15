local order = {
  "definition",
  "declaration",
  "references",
  "implementation",
  "type_definition",
  "incoming_calls",
  "outgoing_calls",
}

-- `placement = "above"` marks actions whose results are callers/consumers of
-- the origin symbol; the sidebar renders them above it so a flow reads
-- top-down from entry points toward the code they reach.
local records = {
  definition = { method = "textDocument/definition", label = "definition" },
  declaration = { method = "textDocument/declaration", label = "declaration" },
  references = {
    method = "textDocument/references",
    label = "usages",
    context = { includeDeclaration = true },
    placement = "above",
  },
  implementation = {
    method = "textDocument/implementation",
    label = "implementations",
  },
  type_definition = {
    method = "textDocument/typeDefinition",
    label = "type definitions",
  },
  incoming_calls = {
    method = "callHierarchy/incomingCalls",
    prepare_method = "textDocument/prepareCallHierarchy",
    label = "callers",
    direction = "incoming",
    placement = "above",
  },
  outgoing_calls = {
    method = "callHierarchy/outgoingCalls",
    prepare_method = "textDocument/prepareCallHierarchy",
    label = "calls",
    direction = "outgoing",
  },
}

local internal = {
  manual = { method = "voyager/manual", label = "manual jump", internal = true },
  archive = {
    method = "voyager/archive",
    label = "archived records",
    internal = true,
    storage = true,
  },
}

local M = {}

function M.names()
  return vim.deepcopy(order)
end

function M.get(name)
  assert(records[name], "unknown Voyager LSP action: " .. tostring(name))
  return vim.deepcopy(records[name])
end

function M.by_method(method)
  for _, name in ipairs(order) do
    if records[name].method == method then
      return name, vim.deepcopy(records[name])
    end
  end
  for name, record in pairs(internal) do
    if record.method == method then
      return name, vim.deepcopy(record)
    end
  end
end

return M
