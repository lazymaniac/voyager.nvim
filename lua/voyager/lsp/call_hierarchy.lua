local M = {}

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

local function combine_failures(...)
  local result = {}
  for _, source in ipairs({ ... }) do
    for _, item in ipairs(source or {}) do
      table.insert(result, vim.deepcopy(item))
    end
  end
  table.sort(result, failure_less)
  return result
end

local function prepared_items(result)
  if result == nil or (type(result) == "table" and next(result) == nil) then
    return {}, true
  end
  if type(result) == "table" and result.uri ~= nil then
    return { result }, false
  end
  if type(result) == "table" and #result > 0 then
    return result, false
  end
  return {}, false
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
    for _, failure in ipairs(failures) do
      if failure.kind ~= "timeout" then
        return "error"
      end
    end
    return "timeout"
  end
  return "error"
end

function M.start(opts)
  local action = vim.deepcopy(opts.action)
  local context = opts.context
  local state = {
    done = false,
    picker_serial = 0,
    prepare_failures = {},
  }
  local handle = {}

  local function outcome(status, items, locations, failures)
    return {
      status = status,
      action = vim.deepcopy(action),
      method = action.method,
      label = action.label,
      origin_node_id = context.origin_node_id,
      items = items or {},
      locations = locations or {},
      failures = failures or {},
    }
  end

  local function finish(value)
    if state.done then
      return
    end
    state.done = true
    state.picker_serial = state.picker_serial + 1
    state.picker_open = false
    state.picker_required = false
    state.stage_marker = nil
    state.active_stage = nil
    opts.on_complete(value)
  end

  local function start_stage(stage_opts, callback)
    local marker = {}
    state.stage_marker = marker
    state.active_stage = nil
    stage_opts.timer = opts.timer
    stage_opts.on_complete = function(stage)
      if state.done or state.stage_marker ~= marker then
        return
      end
      state.stage_marker = nil
      state.active_stage = nil
      callback(stage)
    end
    local stage_handle = opts.request_stage(stage_opts)
    if not state.done and state.stage_marker == marker then
      state.active_stage = stage_handle
    end
  end

  local function start_followup(selected)
    if state.done then
      return
    end
    local supported_ok, supported = pcall(
      selected.client.client.supports_method,
      selected.client.client,
      action.method,
      context.bufnr
    )
    if not supported_ok or not supported then
      finish(outcome("unsupported", {}, {}, combine_failures(state.prepare_failures)))
      return
    end

    start_stage({
      clients = { selected.client },
      method = action.method,
      bufnr = context.bufnr,
      timeout_ms = context.timeout_ms,
      make_params = function()
        return { item = vim.deepcopy(selected.item) }
      end,
    }, function(stage)
      local items = {}
      local locations = {}
      local normalization_failures = {}
      local summary = {
        usable_response_count = 0,
        empty_response_count = 0,
        invalid_response_count = 0,
      }
      for _, response in ipairs(stage.responses) do
        local response_items, response_locations, response_failures, response_summary = opts.normalizer:call_sites(
          action.direction,
          selected.client,
          selected,
          response.result
        )
        vim.list_extend(items, response_items)
        vim.list_extend(locations, response_locations)
        vim.list_extend(normalization_failures, response_failures)
        summary.usable_response_count = summary.usable_response_count + response_summary.usable_response_count
        summary.empty_response_count = summary.empty_response_count + response_summary.empty_response_count
        summary.invalid_response_count = summary.invalid_response_count + response_summary.invalid_response_count
      end
      local failures = combine_failures(state.prepare_failures, stage.failures, normalization_failures)
      finish(outcome(classify(stage, summary, items, failures), items, locations, failures))
    end)
  end

  local function choose_prepared(prepared)
    if #prepared == 1 then
      start_followup(prepared[1])
      return
    end

    state.picker_required = true
    if not opts.owns_presentation(context.request_token) then
      finish(outcome("superseded", {}, {}, combine_failures(state.prepare_failures)))
      return
    end

    state.picker_serial = state.picker_serial + 1
    local picker_token = state.picker_serial
    state.picker_open = true
    opts.select(prepared, {
      prompt = action.label,
      format_item = function(item)
        return string.format("%s · %s", item.item.name or "<anonymous>", item.client.name)
      end,
    }, function(selected)
      if state.done or not state.picker_open or picker_token ~= state.picker_serial then
        return
      end
      if not opts.owns_presentation(context.request_token) then
        finish(outcome("superseded", {}, {}, combine_failures(state.prepare_failures)))
        return
      end
      state.picker_open = false
      state.picker_required = false
      if selected == nil then
        finish(outcome("cancelled", {}, {}, combine_failures(state.prepare_failures)))
        return
      end
      start_followup(selected)
    end)
  end

  function handle:cancel(reason)
    if state.done then
      return
    end
    state.picker_serial = state.picker_serial + 1
    state.picker_open = false
    state.picker_required = false
    local active = state.active_stage
    if active then
      active:cancel(reason)
    end
    if not state.done then
      finish(outcome("cancelled", {}, {}, combine_failures(state.prepare_failures)))
    end
  end

  function handle:supersede_interactive()
    if not state.done and (state.picker_open or state.picker_required) then
      finish(outcome("superseded", {}, {}, combine_failures(state.prepare_failures)))
    end
  end

  function handle:is_done()
    return state.done
  end

  if #opts.clients == 0 then
    finish(outcome("unsupported", {}, {}, {}))
    return handle
  end

  start_stage({
    clients = opts.clients,
    method = action.prepare_method,
    bufnr = context.bufnr,
    timeout_ms = context.timeout_ms,
    make_params = function(snapshot)
      return opts.make_position_params(context.winid, snapshot.offset_encoding)
    end,
  }, function(stage)
    state.prepare_failures = combine_failures(stage.failures)
    if stage.status == "cancelled" then
      finish(outcome("cancelled", {}, {}, state.prepare_failures))
      return
    end

    local flattened = {}
    local has_empty_response = false
    for _, response in ipairs(stage.responses) do
      local items, is_empty = prepared_items(response.result)
      has_empty_response = has_empty_response or is_empty
      for _, item in ipairs(items) do
        table.insert(flattened, {
          client_id = response.client.id,
          client = response.client,
          item = vim.deepcopy(item),
          response_index = #flattened + 1,
        })
      end
    end

    if #flattened == 0 then
      local status
      if has_empty_response then
        status = #state.prepare_failures > 0 and "partial" or "empty"
      elseif stage.status == "timeout" then
        status = "timeout"
      else
        status = "error"
      end
      finish(outcome(status, {}, {}, state.prepare_failures))
      return
    end
    choose_prepared(flattened)
  end)

  return handle
end

return M
