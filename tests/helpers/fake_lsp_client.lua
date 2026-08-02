local M = {}

function M.new(spec)
  spec = spec or {}
  local client = {
    id = assert(spec.id),
    name = assert(spec.name),
    offset_encoding = spec.offset_encoding or "utf-8",
    request_id = spec.request_id or spec.id,
    requests = {},
    cancelled = {},
    methods = {},
    supports_calls = {},
  }

  function client:snapshot()
    return {
      id = self.id,
      name = self.name,
      offset_encoding = self.offset_encoding,
      client = self,
    }
  end

  function client:request(method, params, callback, bufnr)
    if spec.request_error then
      error(spec.request_error)
    end
    table.insert(self.requests, {
      method = method,
      params = vim.deepcopy(params),
      bufnr = bufnr,
      callback = callback,
    })
    table.insert(self.methods, method)
    self.callback = callback
    self.callbacks = self.callbacks or {}
    self.callbacks[method] = callback
    if spec.sync_reply then
      callback(spec.sync_reply.error, vim.deepcopy(spec.sync_reply.result))
    end
    if spec.accepted == false then
      return false, nil
    end
    if spec.missing_request_id then
      return true, nil
    end
    return true, self.request_id
  end

  function client:cancel_request(request_id)
    table.insert(self.cancelled, request_id)
  end

  function client:reply(err, result)
    assert(self.callback, "fake client has no pending request")
    self.callback(err, vim.deepcopy(result))
  end

  function client:reply_late(err, result)
    return self:reply(err, result)
  end

  function client:reply_method(method, err, result)
    assert(self.callbacks and self.callbacks[method], "fake client has no request for " .. method)
    self.callbacks[method](err, vim.deepcopy(result))
  end

  function client:reply_prepare(err, result)
    return self:reply_method("textDocument/prepareCallHierarchy", err, result)
  end

  function client:reply_followup(err, result)
    local method = self.methods[#self.methods]
    assert(method ~= "textDocument/prepareCallHierarchy", "fake client has no follow-up request")
    return self:reply_method(method, err, result)
  end

  function client:supports_method(method, bufnr)
    table.insert(self.supports_calls, { method = method, bufnr = bufnr })
    if type(spec.supports_method) == "function" then
      return spec.supports_method(method, bufnr)
    end
    if type(spec.supported_methods) == "table" and spec.supported_methods[method] ~= nil then
      return spec.supported_methods[method]
    end
    return spec.supports ~= false
  end

  return client
end

return M
