---Goto actions supported by plugins
local lsp_actions = {
  "definition",
  "references",
  "implementation",
  "type_definition",
  "incoming_calls",
  "outgoing_calls",
}

---@class LspModule
---Handles async calls to LSP
local M = {}
-- Utility function to manage spinner display
local spinner_states = { "-", "\\", "|", "/" }
local spinner_index = 1
local spinner_buf = nil

-- Function to show spinner
local function spinner_start()
  if not spinner_buf then
    spinner_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_open_win(spinner_buf, false, {
      relative = "cursor",
      row = 1,
      col = 0,
      width = 10,
      height = 1,
      style = "minimal",
    })
  end
  -- Update spinner every 100ms
  vim.defer_fn(function()
    -- Rotate spinner
    spinner_index = (spinner_index % #spinner_states) + 1
    vim.api.nvim_buf_set_lines(spinner_buf, 0, -1, false, { spinner_states[spinner_index] })
    -- Continue showing spinner if it hasn't been stopped
    if spinner_buf then
      spinner_start()
    end
  end, 100)
end

-- Function to stop spinner
local function spinner_stop()
  if spinner_buf then
    vim.api.nvim_buf_delete(spinner_buf, { force = true })
    spinner_buf = nil
  end
end

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
  local params = vim.lsp.util.make_position_params()

  params.context = {
    includeDeclaration = true,
  }

  coroutine.resume(coroutine.create(function()
    local locations = {}
    local co = coroutine.running()

    spinner_start() -- Start spinner before making the LSP request

    vim.lsp.buf_request_all(curbuf, method, params, function(results)
      spinner_stop() -- Stop spinner as soon as we receive response

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

    callback(locations)
  end))
end

---Get references locations
---@param callback function locations and items consumer
M.get_references = function(callback)
  local method = "textDocument/references"
  print("calling method get_references")
  call_lsp_method(method, callback)
end

---Get definition location and item
---@param callback function locations and items consumer
M.get_definition = function(callback)
  local method = "textDocument/definition"
  call_lsp_method(method, callback)
end

---Get implementations locations and items
---@param callback function locations and items consumer
M.get_implementations = function(callback)
  local method = "textDocument/implementation"
  call_lsp_method(method, callback)
end

---Get type definition location and item
---@param callback function locations and items consumer
M.get_type_definition = function(callback)
  local method = "textDocument/typeDefinition"
  call_lsp_method(method, callback)
end

---Get incoming calls locations and items
---@param callback function locations and items consumer
M.get_incoming_calls = function(callback)
  local method = "callHierarchy/incomingCalls"
  call_lsp_method(method, callback)
end

---Get outgoing calls locations and items
---@param callback function locations and items consumer
M.get_outgoing_calls = function(callback)
  local method = "callHierarchy/outgoingCalls"
  call_lsp_method(method, callback)
end

---Return table with supported lsp goto actions
---@return table table with supported lsp actions
M.get_lsp_actions = function()
  return lsp_actions
end

return M
