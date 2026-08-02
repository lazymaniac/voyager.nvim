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
    self.callback = callback
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

  return client
end

return M
