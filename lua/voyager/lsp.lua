local M = {}
local Lsp = {}
Lsp.__index = Lsp

local function failure_less(left, right)
  local left_name = left.client_name or ""
  local right_name = right.client_name or ""
  if left_name ~= right_name then
    return left_name < right_name
  end
  local left_id = left.client_id or -1
  local right_id = right.client_id or -1
  if left_id ~= right_id then
    return left_id < right_id
  end
  local left_index = left.response_index or -1
  local right_index = right.response_index or -1
  if left_index ~= right_index then
    return left_index < right_index
  end
  return (left.kind or "") < (right.kind or "")
end

local function sorted_failures(transport, normalization)
  local failures = {}
  for _, item in ipairs(transport or {}) do
    table.insert(failures, vim.deepcopy(item))
  end
  for _, item in ipairs(normalization or {}) do
    table.insert(failures, vim.deepcopy(item))
  end
  table.sort(failures, failure_less)
  return failures
end

local function classify(stage, summary, items, failures)
  if stage.status == "cancelled" then
    return "cancelled"
  end
  if summary.usable_response_count > 0 then
    if #failures > 0 then
      return "partial"
    end
    return #items > 0 and "success" or "empty"
  end
  if #failures > 0 then
    for _, item in ipairs(failures) do
      if item.kind ~= "timeout" then
        return "error"
      end
    end
    return "timeout"
  end
  return "error"
end

local function snapshots(clients)
  local result = {}
  for _, client in ipairs(clients) do
    table.insert(result, {
      id = client.id,
      name = client.name,
      offset_encoding = client.offset_encoding,
      client = client,
    })
  end
  return result
end

function M.new(deps)
  assert(type(deps) == "table", "Voyager LSP dependencies are required")
  return setmetatable({
    _actions = deps.actions,
    _normalizer = deps.normalizer,
    _request_group = deps.request_group,
    _call_hierarchy = deps.call_hierarchy or require("voyager.lsp.call_hierarchy"),
    _get_clients = deps.get_clients,
    _make_position_params = deps.make_position_params,
    _timer = deps.timer,
    _select = deps.select,
  }, Lsp)
end

function Lsp:start(action_name, context, on_complete)
  local action = self._actions.get(action_name)
  local state = { done = false }
  local handle = {}

  local function finish(status, items, locations, failures)
    if state.done then
      return
    end
    state.done = true
    on_complete({
      status = status,
      action = vim.deepcopy(action),
      method = action.method,
      label = action.label,
      origin_node_id = context.origin_node_id,
      items = items or {},
      locations = locations or {},
      failures = failures or {},
    })
  end

  function handle:cancel(reason)
    if not state.done and state.request_handle then
      state.request_handle:cancel(reason)
    end
  end

  function handle:supersede_interactive() end

  function handle:is_done()
    return state.done
  end

  self._presentation_token = context.request_token
  local discovery_method = action.prepare_method or action.method
  local clients = snapshots(self._get_clients({ bufnr = context.bufnr, method = discovery_method }))
  if #clients == 0 then
    finish("unsupported", {}, {}, {})
    return handle
  end

  if action.prepare_method then
    state.request_handle = self._call_hierarchy.start({
      action = action,
      context = context,
      clients = clients,
      request_stage = self._request_group.start,
      normalizer = self._normalizer,
      timer = self._timer,
      make_position_params = self._make_position_params,
      select = self._select,
      owns_presentation = function(token)
        return self._presentation_token == token
      end,
      on_complete = function(call_outcome)
        finish(call_outcome.status, call_outcome.items, call_outcome.locations, call_outcome.failures)
      end,
    })
    function handle:supersede_interactive()
      if not state.done and state.request_handle then
        state.request_handle:supersede_interactive()
      end
    end
    return handle
  end

  local function make_params(snapshot)
    local params = self._make_position_params(context.winid, snapshot.offset_encoding)
    if action.context then
      params.context = vim.deepcopy(action.context)
    end
    return params
  end

  state.request_handle = self._request_group.start({
    clients = clients,
    method = action.method,
    bufnr = context.bufnr,
    timeout_ms = context.timeout_ms,
    make_params = make_params,
    timer = self._timer,
    on_complete = function(stage)
      if state.done then
        return
      end
      local items, locations, normalization_failures, summary = self._normalizer:locations(stage.responses)
      local failures = sorted_failures(stage.failures, normalization_failures)
      finish(classify(stage, summary, items, failures), items, locations, failures)
    end,
  })

  return handle
end

return M
