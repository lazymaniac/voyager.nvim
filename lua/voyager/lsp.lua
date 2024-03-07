---@class LspModule
---Handles async calls to LSP
local M = {}

local function res_isempty(results)
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

  -- local spin_close = box.spinner()
  local count = 0
  coroutine.resume(coroutine.create(function()
    local retval = {}
    local co = coroutine.running()
    vim.lsp.buf_request_all(curbuf, method, params, function(results)
      count = count + 1
      if results and not res_isempty(results) then
        retval[method] = results
      end
      coroutine.resume(co)
    end)
    coroutine.yield()
    count = 0

    if retval[method]:empty() then
      vim.notify("No results", vim.log.levels.WARN)
    end

    callback(retval)
  end))
end

---@return string
M.my_first_function = function(greeting)
  return greeting
end

---Returns table with references
---@param callback function consuming references
M.get_references = function(callback)
  local method = "textDocument/references"
  call_lsp_method(method, callback)
end

---Get lsp definition
---@param callback function consuming definition
M.get_definition = function(callback)
  local method = "textDocument/definition"
  call_lsp_method(method, callback)
end

---Returns table with lsp implementations
---@param callback function consuming implementations
M.get_implementations = function(callback)
  local method = "textDocument/implementation"
  call_lsp_method(method, callback)
end

return M
