local VoyagerSpinner = require("voyager.spinner")
local LocationsStack = require("voyager.locations_stack")

---Goto actions supported by plugin
local lsp_actions = {
  "definition",
  "references",
  "implementation",
  "type_definition",
  "incoming_calls",
  "outgoing_calls",
}

local function is_response_empty(results)
  if vim.tbl_isempty(results) then
    return true
  end
  for _, res in pairs(results) do
    if res.result and #res.result > 0 then
      return false
    end
  end
  return true
end

local function call_lsp_method(method, callback)
  local curbuf = vim.api.nvim_get_current_buf()
  local position_params = vim.lsp.util.make_position_params()
  local cword_symbol = vim.fn.expand("<cword>")
  local cline = vim.api.nvim_buf_get_lines(0, position_params.position.line, position_params.position.line + 1, true)[1]

  position_params.context = {
    includeDeclaration = true,
  }

  coroutine.resume(coroutine.create(function()
    local locations = {}
    local co = coroutine.running()

    VoyagerSpinner.start()

    vim.lsp.buf_request_all(curbuf, method, position_params, function(results)
      if not results or vim.tbl_isempty(results) then
        vim.notify("Nothing found")
        return
      end

      if results and not is_response_empty(results) then
        locations = results
      end
      coroutine.resume(co)
    end)
    coroutine.yield()

    LocationsStack.push_locations({ cword_symbol = cword_symbol, cline = cline }, method, locations)
    callback(locations)
    VoyagerSpinner.stop()
  end))
end

---@class VoyagerLsp
---Handles async calls to LSP
local VoyagerLsp = {}

---Get references locations
---@param callback function locations and items consumer
VoyagerLsp.get_references = function(callback)
  local method = "textDocument/references"
  call_lsp_method(method, callback)
end

---Get definition location and item
---@param callback function locations and items consumer
VoyagerLsp.get_definition = function(callback)
  local method = "textDocument/definition"
  call_lsp_method(method, callback)
end

---Get implementations locations and items
---@param callback function locations and items consumer
VoyagerLsp.get_implementation = function(callback)
  local method = "textDocument/implementation"
  call_lsp_method(method, callback)
end

---Get type definition location and item
---@param callback function locations and items consumer
VoyagerLsp.get_type_definition = function(callback)
  local method = "textDocument/typeDefinition"
  call_lsp_method(method, callback)
end

---Get incoming calls locations and items
---@param callback function locations and items consumer
VoyagerLsp.get_incoming_calls = function(callback)
  local method = "callHierarchy/incomingCalls"
  call_lsp_method(method, callback)
end

---Get outgoing calls locations and items
---@param callback function locations and items consumer
VoyagerLsp.get_outgoing_calls = function(callback)
  local method = "callHierarchy/outgoingCalls"
  call_lsp_method(method, callback)
end

---Return table with supported lsp goto actions
---@return table table with supported lsp actions
VoyagerLsp.get_lsp_actions = function()
  return lsp_actions
end

return VoyagerLsp
