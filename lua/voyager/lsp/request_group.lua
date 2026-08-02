local M = {}

local function compare_clients(left, right)
  if left.name == right.name then
    return left.id < right.id
  end
  return left.name < right.name
end

local function error_message(err)
  if type(err) == "table" and type(err.message) == "string" then
    return err.message
  end
  if type(err) == "table" then
    return vim.inspect(err)
  end
  return tostring(err)
end

local function stage_status(responses, failures, cancelled)
  if cancelled then
    return "cancelled"
  end
  if #failures == 0 then
    return "success"
  end
  if #responses > 0 then
    return "partial"
  end
  for _, item in ipairs(failures) do
    if item.kind ~= "timeout" then
      return "error"
    end
  end
  return "timeout"
end

function M.start(opts)
  local clients = {}
  for _, snapshot in ipairs(opts.clients or {}) do
    table.insert(clients, snapshot)
  end
  table.sort(clients, compare_clients)

  local state = {
    cancelled = false,
    dispatching = true,
    done = false,
    failures = {},
    pending = #clients,
    responses = {},
    slots = {},
  }
  for _, snapshot in ipairs(clients) do
    table.insert(state.slots, { pending = true, snapshot = snapshot })
  end

  local handle = {}
  local maybe_finalize

  local function settle(slot, kind, value)
    if state.done or not slot.pending then
      return false
    end
    slot.pending = false
    state.pending = state.pending - 1
    if kind == "response" then
      table.insert(state.responses, { client = slot.snapshot, result = value })
    else
      table.insert(state.failures, {
        kind = kind,
        client_id = slot.snapshot.id,
        client_name = slot.snapshot.name,
        message = value,
      })
    end
    return true
  end

  local function cancel_request(slot)
    local request_id = slot.request_id
    if request_id ~= nil then
      pcall(slot.snapshot.client.cancel_request, slot.snapshot.client, request_id)
    end
  end

  local function finish()
    if state.done or state.pending > 0 then
      return
    end
    state.done = true
    state.timer:cancel()
    state.timer:close()
    table.sort(state.responses, function(left, right)
      return compare_clients(left.client, right.client)
    end)
    table.sort(state.failures, function(left, right)
      if left.client_name == right.client_name then
        if left.client_id == right.client_id then
          return left.kind < right.kind
        end
        return left.client_id < right.client_id
      end
      return left.client_name < right.client_name
    end)
    opts.on_complete({
      status = stage_status(state.responses, state.failures, state.cancelled),
      responses = state.responses,
      failures = state.failures,
    })
  end

  maybe_finalize = function()
    if not state.dispatching then
      finish()
    end
  end

  state.timer = opts.timer(opts.timeout_ms, function()
    if state.done then
      return
    end
    for _, slot in ipairs(state.slots) do
      if settle(slot, "timeout", string.format("LSP request timed out after %d ms", opts.timeout_ms)) then
        cancel_request(slot)
      end
    end
    maybe_finalize()
  end)

  for _, slot in ipairs(state.slots) do
    local snapshot = slot.snapshot
    local callback = function(err, result)
      if err ~= nil then
        settle(slot, "protocol", error_message(err))
      else
        settle(slot, "response", result)
      end
      maybe_finalize()
    end

    local call_ok, dispatched, request_id = pcall(function()
      local params = opts.make_params(snapshot)
      return snapshot.client:request(opts.method, params, callback, opts.bufnr)
    end)
    if not call_ok or dispatched ~= true or request_id == nil then
      settle(slot, "setup", call_ok and "client rejected request" or tostring(dispatched))
    elseif slot.pending then
      slot.request_id = request_id
    end
  end

  state.dispatching = false
  maybe_finalize()

  function handle:cancel(reason)
    if state.done then
      return
    end
    state.cancelled = true
    for _, slot in ipairs(state.slots) do
      if settle(slot, "cancelled", reason) then
        cancel_request(slot)
      end
    end
    maybe_finalize()
  end

  function handle:is_done()
    return state.done
  end

  return handle
end

return M
