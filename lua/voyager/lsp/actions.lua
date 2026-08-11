local order = {
  "definition",
  "declaration",
  "references",
  "implementation",
  "type_definition",
  "incoming_calls",
  "outgoing_calls",
}

local records = {
  definition = { method = "textDocument/definition", label = "definition" },
  declaration = { method = "textDocument/declaration", label = "declaration" },
  references = {
    method = "textDocument/references",
    label = "references",
    context = { includeDeclaration = true },
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
    label = "incoming calls",
    direction = "incoming",
  },
  outgoing_calls = {
    method = "callHierarchy/outgoingCalls",
    prepare_method = "textDocument/prepareCallHierarchy",
    label = "outgoing calls",
    direction = "outgoing",
  },
}

local internal = {
  manual = { method = "voyager/manual", label = "manual jump" },
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
  if internal.manual.method == method then
    return "manual", vim.deepcopy(internal.manual)
  end
end

return M
