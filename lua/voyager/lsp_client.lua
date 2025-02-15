local Spinner = require("voyager.spinner")
local LocationsStack = require("voyager.locations_stack")

---LSP methods supported by plugin
local lsp_actions = {
  "definition",
  "references",
  "implementation",
  "type_definition",
  "incoming_calls",
  "outgoing_calls",
}

local function are_results_empty(results)
  return vim.tbl_isempty(results) or not next(vim.tbl_filter(function(result_item)
    return result_item.result and #result_item.result > 0
  end, results))
end

local function call_lsp_method(method, callback)
  local curbuf = vim.api.nvim_get_current_buf()
  local position_params = vim.lsp.util.make_position_params()

  position_params.context = {
    includeDeclaration = true,
  }

  coroutine.resume(coroutine.create(function()
    local co = coroutine.running()

    Spinner.start()

    vim.lsp.buf_request_all(curbuf, method, position_params, function(results)
      if not results or vim.tbl_isempty(results) then
        vim.notify("Nothing found")
        return
      end

      if results and not are_results_empty(results) then
        -- Build parent dtails
        local parent = {
          cword_symbol = vim.fn.expand("<cword>"),
          cline = vim.api.nvim_buf_get_lines(0, position_params.position.line, position_params.position.line + 1, true)[1],
          cfile = position_params.textDocument.uri:gsub("file://", ""):gsub(vim.fn.getcwd(), ".."),
          line_num = position_params.position.line,
        }
        LocationsStack.push_locations(parent, method, results)
        callback()
      end
      coroutine.resume(co)
    end)
    coroutine.yield()

    Spinner.stop()
  end))
end

---@class LspClient
---Handles async calls to LSP
local LspClient = {}

---Get references locations
---@param callback function
LspClient.get_references = function(callback)
  local method = "textDocument/references"
  call_lsp_method(method, callback)
end

---Get definition location and item
---@param callback function
LspClient.get_definition = function(callback)
  local method = "textDocument/definition"
  call_lsp_method(method, callback)
end

---Get implementations locations and items
---@param callback function
LspClient.get_implementation = function(callback)
  local method = "textDocument/implementation"
  call_lsp_method(method, callback)
end

---Get type definition location and item
---@param callback function
LspClient.get_type_definition = function(callback)
  local method = "textDocument/typeDefinition"
  call_lsp_method(method, callback)
end

---Get incoming calls locations and items
---@param callback function
LspClient.get_incoming_calls = function(callback)
  local method = "callHierarchy/incomingCalls"
  call_lsp_method(method, callback)
end

---Get outgoing calls locations and items
---@param callback function
LspClient.get_outgoing_calls = function(callback)
  local method = "callHierarchy/outgoingCalls"
  call_lsp_method(method, callback)
end

---Return table with supported lsp goto actions
---@return table table with supported lsp actions
LspClient.get_lsp_actions = function()
  return lsp_actions
end

return LspClient
