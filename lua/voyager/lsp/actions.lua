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
  definition = { method = "textDocument/definition", label = "definition", presentation = "jump_or_list" },
  declaration = { method = "textDocument/declaration", label = "declaration", presentation = "jump_or_list" },
  references = {
    method = "textDocument/references",
    label = "references",
    presentation = "always_list",
    context = { includeDeclaration = true },
  },
  implementation = {
    method = "textDocument/implementation",
    label = "implementations",
    presentation = "jump_or_list",
  },
  type_definition = {
    method = "textDocument/typeDefinition",
    label = "type definitions",
    presentation = "jump_or_list",
  },
  incoming_calls = {
    method = "callHierarchy/incomingCalls",
    prepare_method = "textDocument/prepareCallHierarchy",
    label = "incoming calls",
    presentation = "always_list",
    direction = "incoming",
  },
  outgoing_calls = {
    method = "callHierarchy/outgoingCalls",
    prepare_method = "textDocument/prepareCallHierarchy",
    label = "outgoing calls",
    presentation = "always_list",
    direction = "outgoing",
  },
}

local internal = {
  manual = { method = "voyager/manual", label = "manual jump", presentation = "none" },
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
