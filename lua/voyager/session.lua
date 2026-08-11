local Locator = require("voyager.locator")
local Actions = require("voyager.lsp.actions")

local M = {}
local Session = {}
Session.__index = Session

local active_phases = {
  active = true,
  deciding = true,
  saving = true,
}

local committing_statuses = {
  success = true,
  partial = true,
  empty = true,
}

local function normalize(path)
  local value = path:gsub("\\", "/")
  return vim.fs.normalize(value, { expand_env = false })
end

local function trim_root(path)
  if path == "/" then
    return path
  end
  return path:gsub("/+$", "")
end

local function contains(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function realpath(runtime, path)
  local normalized = normalize(path)
  return trim_root(normalize(runtime.fs_realpath(normalized) or normalized))
end

local function project_root(runtime, bufnr)
  local file = realpath(runtime, runtime.buffer_name(bufnr))
  local roots = {}
  for _, client in ipairs(runtime.get_clients({ bufnr = bufnr }) or {}) do
    local root = client.config and client.config.root_dir
    if type(root) == "string" and root ~= "" then
      root = realpath(runtime, root)
      if contains(file, root) then
        table.insert(roots, root)
      end
    end
  end
  table.sort(roots, function(left, right)
    return #left > #right
  end)
  if roots[1] then
    return roots[1]
  end
  local git_root = runtime.find_root(file, ".git")
  if git_root then
    return realpath(runtime, git_root)
  end
  local cwd = realpath(runtime, runtime.cwd())
  if contains(file, cwd) then
    return cwd
  end
  return realpath(runtime, runtime.dirname(file))
end

function M.new(opts)
  assert(type(opts) == "table", "Voyager session dependencies are required")
  return setmetatable({
    _config_provider = opts.config_provider,
    _runtime = opts.runtime,
    _flow_module = opts.flow,
    _locator_factory = opts.locator_factory,
    _store_factory = opts.store_factory,
    _sidebar_factory = opts.sidebar_factory,
    _lsp_factory = opts.lsp_factory,
    _ui = opts.ui,
    _generation = 0,
    _recording = 0,
    _interaction_counter = 0,
    _interaction_tokens = {},
  }, Session)
end

function Session:is_active()
  return self._state ~= nil and active_phases[self._state.phase] == true
end

function Session:state()
  return self._state
end

function Session:_is_normal_named_buffer(bufnr)
  local runtime = self._runtime
  if not runtime.buffer_valid(bufnr) or not runtime.buffer_loaded(bufnr) then
    return false
  end
  local name = runtime.buffer_name(bufnr)
  return type(name) == "string" and name ~= "" and runtime.buffer_option(bufnr, "buftype") == ""
end

function Session:_buffer_in_flow(state, name)
  for _, node in ipairs(state.flow:dfs()) do
    if node.kind == "location" then
      local locator = node.location.locator
      if locator.kind == "uri" and locator.uri == name then
        return true
      end
      if locator.kind == "absolute" and realpath(self._runtime, locator.path) == realpath(self._runtime, name) then
        return true
      end
      if
        locator.kind == "project"
        and realpath(self._runtime, state.project_root .. "/" .. locator.path) == realpath(self._runtime, name)
      then
        return true
      end
    end
  end
  return false
end

function Session:_eligible_buffer(state, bufnr)
  if not self:_is_normal_named_buffer(bufnr) then
    return false
  end
  if self._runtime.buffer_option(bufnr, "buflisted") == false then
    return false
  end
  local name = self._runtime.buffer_name(bufnr)
  local path = realpath(self._runtime, name)
  return contains(path, state.project_root) or self:_buffer_in_flow(state, name)
end

function Session:_eligible_window(state, winid)
  local runtime = self._runtime
  return runtime.win_valid(winid)
    and runtime.win_config(winid).relative == ""
    and self:_eligible_buffer(state, runtime.win_buf(winid))
end

function Session:_record_source_window(state, winid)
  if not self:_eligible_window(state, winid) then
    return
  end
  local next_windows = { winid }
  for _, candidate in ipairs(state.source_windows) do
    if candidate ~= winid then
      table.insert(next_windows, candidate)
    end
  end
  state.source_windows = next_windows
end

function Session:_stage_state(opts)
  local config = opts.config
  local locator = opts.locator or self._locator_factory(opts.project_root, config.storage.resolve_uri)
  local store = opts.store or self._store_factory(locator)
  local state = {
    phase = opts.phase or "active",
    generation = opts.generation,
    config = config,
    flow = opts.flow,
    project_root = opts.project_root,
    request_count = 0,
    request_handles = {},
    request_token = 0,
    interaction_token = 0,
    interaction_tokens = {},
    tracking_token = 0,
    destination_claim = nil,
    observer_pending = {},
    current_claim_token = 0,
    manual_claim_token = 0,
    source_windows = vim.deepcopy(opts.source_windows or { opts.origin_win }),
    origin_buf = opts.origin_buf,
    origin_win = opts.origin_win,
    tabpage = opts.tabpage,
    locator = locator,
    store = store,
  }
  state.sidebar = self._sidebar_factory(config)
  state.lsp = self._lsp_factory(locator, config)
  return state
end

function Session:_render(state)
  state.sidebar:render(state.flow, {
    dirty = state.flow:is_dirty(),
    request_count = state.request_count,
  })
end

local function first_failure_message(outcome)
  local failure = type(outcome.failures) == "table" and outcome.failures[1] or nil
  if type(failure) == "table" and type(failure.message) == "string" and failure.message ~= "" then
    return failure.message
  end
end

function Session:_notify_outcome(outcome)
  local label = type(outcome.label) == "string" and outcome.label or "navigation"
  local status = outcome.status
  local message
  local level = vim.log.levels.WARN
  if status == "partial" then
    local count = type(outcome.failures) == "table" and #outcome.failures or 0
    message = string.format("Voyager: %s completed with %d issue%s", label, count, count == 1 and "" or "s")
  elseif status == "empty" then
    message = "Voyager: " .. label .. " returned no results"
    level = vim.log.levels.INFO
  elseif status == "error" then
    message = "Voyager: " .. label .. " failed: " .. (first_failure_message(outcome) or "request failed")
    level = vim.log.levels.ERROR
  elseif status == "timeout" then
    message = "Voyager: " .. label .. " timed out"
  elseif status == "unsupported" then
    message = "Voyager: " .. label .. " is not supported"
  elseif status == "cancelled" then
    message = "Voyager: " .. label .. " was cancelled"
  elseif status == "superseded" then
    message = "Voyager: " .. label .. " was superseded"
    level = vim.log.levels.INFO
  end
  if message then
    self._ui.notify(message, level)
  end
end

function Session:_observe_lsp_request(state, args)
  if self._recording > 0 then
    return
  end
  local data = type(args.data) == "table" and args.data or {}
  local request = type(data.request) == "table" and data.request or nil
  if not request or request.type ~= "pending" then
    return
  end
  local action_name = Actions.by_method(request.method)
  if not action_name or action_name == "manual" then
    return
  end
  local runtime = self._runtime
  local winid = runtime.current_win()
  if request.bufnr ~= runtime.current_buf() or not self:_eligible_window(state, winid) then
    return
  end
  if state.observer_pending[action_name] then
    return
  end
  state.observer_pending[action_name] = true
  runtime.schedule(function()
    if self._state == state then
      state.observer_pending[action_name] = nil
    end
  end)
  local recorded, record_error = pcall(self.run_action, self, action_name)
  if not recorded then
    self._ui.notify("Voyager: could not record " .. action_name .. ": " .. tostring(record_error), vim.log.levels.ERROR)
  end
end

function Session:_valid_state(state, generation)
  return self._state == state and self:is_active() and state.generation == generation
end

function Session:_remount_for_event(state)
  state.sidebar:remount({
    tabpage = self._runtime.current_tabpage(),
    focus = false,
  })
end

function Session:_register_autocmds(state)
  local runtime = self._runtime
  local generation = state.generation
  state.autocmd_group = runtime.create_augroup("VoyagerSession", { clear = true })
  local function guarded(callback)
    return function(args)
      if self:_valid_state(state, generation) then
        callback(args or {})
      end
    end
  end

  runtime.create_autocmd("LspRequest", {
    group = state.autocmd_group,
    callback = guarded(function(args)
      self:_observe_lsp_request(state, args)
    end),
  })
  runtime.create_autocmd("WinEnter", {
    group = state.autocmd_group,
    callback = guarded(function()
      local winid = runtime.current_win()
      self:_record_source_window(state, winid)
    end),
  })
  runtime.create_autocmd("CursorMoved", {
    group = state.autocmd_group,
    callback = guarded(function()
      self:_check_destination_claim(state, runtime.current_win())
    end),
  })
  runtime.create_autocmd("WinClosed", {
    group = state.autocmd_group,
    callback = guarded(function(args)
      local closed = tonumber(args.match)
      if closed then
        state.source_windows = vim.tbl_filter(function(winid)
          return winid ~= closed
        end, state.source_windows)
      end
    end),
  })
  runtime.create_autocmd("TabEnter", {
    group = state.autocmd_group,
    callback = guarded(function()
      self:_remount_for_event(state)
    end),
  })
  runtime.create_autocmd("VimResized", {
    group = state.autocmd_group,
    callback = guarded(function()
      self:_remount_for_event(state)
    end),
  })
  runtime.create_autocmd("VimLeavePre", {
    group = state.autocmd_group,
    callback = guarded(function()
      self:shutdown()
    end),
  })
end

function Session:_delete_autocmds(state)
  if state.autocmd_group then
    self._runtime.delete_augroup(state.autocmd_group)
    state.autocmd_group = nil
  end
end

function Session:open()
  if self:is_active() then
    return self:focus()
  end
  local runtime = self._runtime
  local origin_buf = runtime.current_buf()
  local origin_win = runtime.current_win()
  if not self:_is_normal_named_buffer(origin_buf) or not runtime.win_valid(origin_win) then
    self._ui.notify("Voyager: open requires a normal named buffer", vim.log.levels.WARN)
    return nil
  end

  local config = self._config_provider()
  local root_dir = project_root(runtime, origin_buf)
  local locator = self._locator_factory(root_dir, config.storage.resolve_uri)
  local store = self._store_factory(locator)
  local root, root_error = Locator.capture_root(origin_buf, origin_win, root_dir, runtime)
  if not root then
    self._ui.notify("Voyager: could not capture root: " .. tostring(root_error), vim.log.levels.ERROR)
    return nil
  end
  local nonce, nonce_error = runtime.random(16)
  if not nonce then
    self._ui.notify(
      "Voyager: could not create flow: " .. tostring(nonce_error or "entropy unavailable"),
      vim.log.levels.ERROR
    )
    return nil
  end
  local flow_id = Locator.flow_id(root, 8)
  local flow = self._flow_module.new({
    root = root,
    name = Locator.flow_name(root),
    flow_id = flow_id,
    root_key = Locator.root_key(root),
    now = runtime.now,
    next_id = Locator.id_factory(flow_id, nonce, 0, runtime.sha256),
  })
  local generation = math.max(self._generation, self._state and self._state.generation or 0) + 1
  local staged = self:_stage_state({
    generation = generation,
    config = config,
    flow = flow,
    project_root = root_dir,
    locator = locator,
    store = store,
    origin_buf = origin_buf,
    origin_win = origin_win,
    tabpage = runtime.current_tabpage(),
  })

  local mounted, mount_error = staged.sidebar:mount({ tabpage = staged.tabpage, focus = false })
  if not mounted then
    staged.sidebar:unmount({ owned = true })
    self._ui.notify("Voyager: could not open sidebar: " .. tostring(mount_error), vim.log.levels.ERROR)
    return nil
  end

  self._generation = generation
  self._state = staged
  self:_register_autocmds(staged)
  self:_render(staged)
  return true
end

function Session:focus()
  if not self:is_active() then
    self._ui.notify("Voyager: no active flow", vim.log.levels.INFO)
    return nil
  end
  local state = self._state
  if state.sidebar:is_mounted() then
    return state.sidebar:focus()
  end
  local mounted, reason = state.sidebar:remount({
    tabpage = self._runtime.current_tabpage(),
    focus = true,
  })
  if not mounted then
    self._ui.notify("Voyager: " .. tostring(reason), vim.log.levels.WARN)
    return nil
  end
  return true
end

function Session:choose_jump_window()
  if not self:is_active() then
    return nil
  end
  local state = self._state
  local retained = {}
  for _, winid in ipairs(state.source_windows) do
    if self:_eligible_window(state, winid) then
      table.insert(retained, winid)
    end
  end
  state.source_windows = retained
  if retained[1] then
    return retained[1]
  end
  local current_tabpage = self._runtime.current_tabpage()
  for _, winid in ipairs(self._runtime.list_wins()) do
    if self:_eligible_window(state, winid) and self._runtime.win_tab(winid) == current_tabpage then
      self:_record_source_window(state, winid)
      return winid
    end
  end
  self._ui.notify("Voyager: no eligible source window is available", vim.log.levels.WARN)
  return nil
end

function Session:_action_context(state, winid, bufnr)
  local cursor = self._runtime.cursor(winid)
  local captured, capture_error = Locator.capture_root(bufnr, winid, state.project_root, self._runtime)
  if not captured then
    return nil, capture_error
  end
  captured.identity = Locator.location_key(captured)

  local origin_node_id = state.flow.current_node_id
  local origin = state.flow:location(origin_node_id)
  if not origin then
    return nil, "logical current location is missing"
  end
  local manual_location
  if not Locator.contains(origin.location, captured.locator, cursor) then
    manual_location = vim.deepcopy(captured)
  end

  return {
    generation = state.generation,
    flow_id = state.flow.flow_id,
    origin_node_id = origin_node_id,
    bufnr = bufnr,
    winid = winid,
    project_root = state.project_root,
    timeout_ms = state.config.navigation.timeout_ms,
    cursor = vim.deepcopy(cursor),
    cursor_locator = vim.deepcopy(captured.locator),
    cursor_range = vim.deepcopy(captured.range),
    manual_location = manual_location,
  }
end

function Session:_commit_outcome(state, context, request_token, outcome)
  assert(outcome.origin_node_id == context.origin_node_id, "navigation origin changed during request")
  assert(type(outcome.method) == "string" and outcome.method ~= "", "navigation method is missing")
  assert(type(outcome.label) == "string" and outcome.label ~= "", "navigation label is missing")

  local identities = {}
  for _, location in ipairs(outcome.locations or {}) do
    local identity = location.identity or Locator.location_key(location)
    identities[identity] = true
  end
  for _, item in ipairs(outcome.items or {}) do
    assert(type(item.identity) == "string" and identities[item.identity], "navigation item identity is missing")
  end

  local commit = state.flow:commit_navigation({
    origin_node_id = outcome.origin_node_id,
    manual_location = context.manual_location,
    method = outcome.method,
    label = outcome.label,
    locations = outcome.locations or {},
  })
  local tagged_items = {}
  for _, item in ipairs(outcome.items or {}) do
    local node_id = assert(commit.node_id_by_identity[item.identity], "committed result identity is missing")
    local tagged = vim.deepcopy(item)
    tagged.node_id = node_id
    table.insert(tagged_items, tagged)
  end

  if
    context.manual_location
    and state.manual_claim_token == request_token
    and state.current_claim_token == request_token
  then
    state.flow:set_current(commit.effective_origin_id)
  end
  return tagged_items
end

function Session:run_action(action_name)
  if not self:is_active() then
    self._ui.notify("Voyager: no active flow", vim.log.levels.INFO)
    return nil
  end
  local action_ok, action = pcall(Actions.get, action_name)
  if not action_ok then
    self._ui.notify("Voyager: " .. tostring(action), vim.log.levels.ERROR)
    return nil
  end

  local state = self._state
  local generation = state.generation
  local flow_id = state.flow.flow_id
  local winid = self._runtime.current_win()
  if not self:_eligible_window(state, winid) then
    self._ui.notify("Voyager: navigation requires an eligible source window", vim.log.levels.WARN)
    return nil
  end
  local bufnr = self._runtime.win_buf(winid)
  local context, context_error = self:_action_context(state, winid, bufnr)
  if not context then
    self._ui.notify("Voyager: could not capture navigation origin: " .. tostring(context_error), vim.log.levels.ERROR)
    return nil
  end

  state.request_token = state.request_token + 1
  local request_token = state.request_token
  context.request_token = request_token
  state.tracking_token = request_token
  state.destination_claim = nil
  state.current_claim_token = request_token
  state.manual_claim_token = context.manual_location and request_token or 0

  local older_handles = {}
  for _, handle in pairs(state.request_handles) do
    table.insert(older_handles, handle)
  end
  for _, handle in ipairs(older_handles) do
    if type(handle.supersede_interactive) == "function" then
      pcall(handle.supersede_interactive, handle)
    end
  end

  state.request_count = state.request_count + 1
  self:_render(state)

  local settled = false
  local function settle(outcome)
    if settled then
      return
    end
    settled = true
    if not self:_valid_state(state, generation) or state.flow.flow_id ~= flow_id then
      return
    end

    state.request_handles[request_token] = nil
    assert(state.request_count > 0, "Voyager request counter underflow")
    state.request_count = state.request_count - 1

    local tagged_items
    if type(outcome) == "table" and committing_statuses[outcome.status] then
      local commit_ok, commit_result = pcall(self._commit_outcome, self, state, context, request_token, outcome)
      if commit_ok then
        tagged_items = commit_result
        self:_notify_outcome(outcome)
      else
        self._ui.notify("Voyager: " .. action.label .. " failed: " .. tostring(commit_result), vim.log.levels.ERROR)
      end
    else
      outcome = type(outcome) == "table" and outcome
        or {
          status = "error",
          label = action.label,
          failures = { { kind = "setup", message = "invalid LSP completion" } },
        }
      self:_notify_outcome(outcome)
    end

    self:_render(state)
    if
      tagged_items
      and #tagged_items > 0
      and self:_valid_state(state, generation)
      and state.flow.flow_id == flow_id
      and state.tracking_token == request_token
    then
      self:_arm_destination_claim(state, context, tagged_items)
    end
  end

  local started, handle = pcall(state.lsp.start, state.lsp, action_name, vim.deepcopy(context), settle)
  if not started then
    settle({
      status = "error",
      action = action,
      method = action.method,
      label = action.label,
      origin_node_id = context.origin_node_id,
      items = {},
      locations = {},
      failures = { { kind = "setup", message = tostring(handle) } },
    })
    return nil
  end
  if type(handle) ~= "table" then
    settle({
      status = "error",
      action = action,
      method = action.method,
      label = action.label,
      origin_node_id = context.origin_node_id,
      items = {},
      locations = {},
      failures = { { kind = "setup", message = "LSP request did not return a handle" } },
    })
    return nil
  end

  local done = false
  if type(handle.is_done) == "function" then
    local done_ok, result = pcall(handle.is_done, handle)
    done = done_ok and result == true
  end
  if not settled and self:_valid_state(state, generation) and state.flow.flow_id == flow_id and not done then
    state.request_handles[request_token] = handle
  end
  return handle
end

function Session:_make_current(state, node_id)
  if not state.flow:location(node_id) then
    return false
  end
  if not state.flow:set_current(node_id) then
    return false
  end
  state.current_claim_token = 0
  state.manual_claim_token = 0
  self:_render(state)
  return true
end

function Session:set_current(node_id)
  if not self:is_active() then
    return false
  end
  local state = self._state
  state.destination_claim = nil
  return self:_make_current(state, node_id)
end

function Session:_arm_destination_claim(state, context, tagged_items)
  local targets = {}
  for _, item in ipairs(tagged_items) do
    local list_item = item.list_item
    if
      type(item.node_id) == "string"
      and type(list_item) == "table"
      and type(list_item.lnum) == "number"
      and type(list_item.col) == "number"
    then
      table.insert(targets, {
        node_id = item.node_id,
        bufnr = list_item.bufnr,
        filename = list_item.filename,
        lnum = list_item.lnum,
        col = list_item.col,
      })
    end
  end
  if #targets == 0 then
    state.destination_claim = nil
    return
  end
  state.destination_claim = {
    generation = state.generation,
    flow_id = state.flow.flow_id,
    request_token = context.request_token,
    targets = targets,
  }
end

function Session:_check_destination_claim(state, winid)
  local claim = state.destination_claim
  if not claim then
    return
  end
  if
    claim.generation ~= state.generation
    or claim.flow_id ~= state.flow.flow_id
    or claim.request_token ~= state.tracking_token
  then
    state.destination_claim = nil
    return
  end
  if not self:_eligible_window(state, winid) then
    return
  end
  local runtime = self._runtime
  local bufnr = runtime.win_buf(winid)
  local cursor = runtime.cursor(winid)
  local buffer_path
  for _, target in ipairs(claim.targets) do
    if cursor.line == target.lnum - 1 and cursor.character == target.col - 1 then
      local matches = false
      if type(target.bufnr) == "number" then
        matches = target.bufnr == bufnr
      elseif type(target.filename) == "string" then
        buffer_path = buffer_path or realpath(runtime, runtime.buffer_name(bufnr))
        matches = buffer_path == realpath(runtime, target.filename)
      end
      if matches then
        self:_make_current(state, target.node_id)
        return
      end
    end
  end
end

function Session:_replace_interaction_token(kind)
  self._interaction_counter = self._interaction_counter + 1
  local state = self._state
  local token = {
    kind = kind,
    value = self._interaction_counter,
    state = state,
    generation = state and state.generation or self._generation,
    flow_id = state and state.flow and state.flow.flow_id or nil,
    active = self:is_active(),
  }
  self._interaction_tokens[kind] = token.value
  return token
end

function Session:_valid_interaction(token)
  if type(token) ~= "table" or self._interaction_tokens[token.kind] ~= token.value then
    return false
  end
  if token.active ~= self:is_active() or token.state ~= self._state then
    return false
  end
  if token.active then
    local state = self._state
    return state.generation == token.generation and state.flow.flow_id == token.flow_id
  end
  return self._generation == token.generation
end

function Session:_consume_interaction(token)
  if not self:_valid_interaction(token) then
    return false
  end
  self._interaction_tokens[token.kind] = nil
  return true
end

function Session:_notify_inapplicable(operation, row)
  local kind = type(row) == "table" and row.kind or "unknown"
  self._ui.notify(string.format("Voyager: cannot %s from a %s row", operation, kind), vim.log.levels.INFO)
end

function Session:_jump_to_location(state, node_id, mark_current)
  if self._state ~= state or not self:is_active() then
    return false
  end
  local node = state.flow:location(node_id)
  if not node then
    self._ui.notify("Voyager: location is no longer available", vim.log.levels.WARN)
    return false
  end
  local winid = self:choose_jump_window()
  if not winid then
    return false
  end
  local target, reason = state.locator:open_target(node.location)
  if not target then
    node.stale = true
    node.stale_reason = tostring(reason or "location is stale")
    self:_render(state)
    self._ui.notify(
      "Voyager: could not open " .. tostring(node.location.symbol or "location") .. ": " .. node.stale_reason,
      vim.log.levels.WARN
    )
    return false
  end

  local was_stale = node.stale == true
  node.stale = false
  node.stale_reason = nil
  self._runtime.set_current_win(winid)
  self._runtime.set_win_buf(winid, target.bufnr)
  self._runtime.set_win_cursor(winid, { target.row, target.col })
  self._runtime.open_folds(winid)
  self:_record_source_window(state, winid)
  if mark_current == false then
    if was_stale then
      self:_render(state)
    end
    return true
  end
  if not self:set_current(node_id) and was_stale then
    self:_render(state)
  end
  return true
end

function Session:activate_row(row)
  if not self:is_active() then
    return false
  end
  if type(row) ~= "table" or type(row.owner_id) ~= "string" then
    self:_notify_inapplicable("activate", row)
    return false
  end
  if row.kind == "action" then
    return self:toggle_row(row)
  end
  if row.kind ~= "location" and row.kind ~= "note" then
    self:_notify_inapplicable("activate", row)
    return false
  end
  return self:_jump_to_location(self._state, row.owner_id, true)
end

function Session:toggle_row(row)
  if not self:is_active() then
    return false
  end
  local node = type(row) == "table" and self._state.flow:find(row.owner_id) or nil
  if type(row) ~= "table" or row.kind ~= "action" or not node or node.kind ~= "action" then
    self:_notify_inapplicable("toggle", row)
    return false
  end
  local changed = self._state.flow:toggle(row.owner_id)
  if changed then
    self:_render(self._state)
  end
  return changed
end

local function normalize_note(value)
  local normalized = vim.trim(value:gsub("[\r\n]+", " "))
  return normalized ~= "" and normalized or nil
end

function Session:edit_note(row)
  if not self:is_active() then
    return nil
  end
  if type(row) ~= "table" or (row.kind ~= "location" and row.kind ~= "note") then
    self:_notify_inapplicable("edit a note", row)
    return nil
  end
  local state = self._state
  local node_id = row.owner_id
  local node = state.flow:location(node_id)
  if not node then
    self._ui.notify("Voyager: note location is no longer available", vim.log.levels.WARN)
    return nil
  end
  local token = self:_replace_interaction_token("note_input")
  self._ui.input({
    prompt = "Voyager note",
    default = node.note,
  }, function(value)
    if not self:_consume_interaction(token) or value == nil or type(value) ~= "string" then
      return
    end
    local active = self._state
    if not active or not active.flow:location(node_id) then
      return
    end
    if active.flow:set_note(node_id, normalize_note(value)) then
      self:_render(active)
    end
  end)
  return true
end

function Session:_invalidate_interactions(state)
  state.interaction_token = state.interaction_token + 1
  state.interaction_tokens = {}
  self._interaction_counter = self._interaction_counter + 1
  self._interaction_tokens = {}
  state.tracking_token = state.tracking_token + 1
  state.destination_claim = nil
  state.current_claim_token = state.current_claim_token + 1
  state.manual_claim_token = state.manual_claim_token + 1
end

function Session:_lifecycle_busy(operation)
  local phase = self._state and self._state.phase or "inactive"
  self._ui.notify(string.format("Voyager: cannot %s while session is %s", operation, phase), vim.log.levels.INFO)
end

function Session:_remount_after_interaction(state)
  if self._state ~= state or not self:is_active() then
    return false
  end
  if not state.sidebar:is_mounted() then
    local mounted, reason = state.sidebar:remount({
      tabpage = self._runtime.current_tabpage(),
      focus = false,
    })
    if not mounted then
      self._ui.notify("Voyager: " .. tostring(reason), vim.log.levels.WARN)
      return false
    end
  end
  self:_render(state)
  return true
end

function Session:_decide_dirty(intent, continuation)
  local state = self._state
  if not state or state.phase ~= "active" then
    self:_lifecycle_busy(intent)
    return false
  end
  state.phase = "deciding"
  self._interaction_tokens.note_input = nil
  self._interaction_tokens.flow_picker = nil
  local token = self:_replace_interaction_token("dirty_decision")
  local selected, select_error = pcall(self._ui.select, { "Save", "Discard", "Cancel" }, {
    prompt = "Save changes to Voyager flow?",
  }, function(choice)
    if not self:_consume_interaction(token) or self._state ~= state or state.phase ~= "deciding" then
      return
    end
    state.phase = "active"
    if choice == "Save" then
      self:save(continuation)
    elseif choice == "Discard" then
      continuation()
    else
      self:_remount_after_interaction(state)
    end
  end)
  if not selected then
    if self:_consume_interaction(token) and self._state == state and state.phase == "deciding" then
      state.phase = "active"
      self._ui.notify("Voyager: dirty-decision UI failed: " .. tostring(select_error), vim.log.levels.ERROR)
      self:_remount_after_interaction(state)
    end
    return false
  end
  return true
end

function Session:save(on_success)
  if not self:is_active() then
    self._ui.notify("Voyager: no active flow to save", vim.log.levels.INFO)
    return nil
  end
  local state = self._state
  if state.phase ~= "active" then
    self:_lifecycle_busy("save")
    return nil
  end

  state.phase = "saving"
  local called, saved, reason = pcall(state.store.save, state.store, state.flow)
  if not called then
    reason = saved
    saved = nil
  end
  if self._state ~= state or state.phase ~= "saving" then
    return nil
  end
  state.phase = "active"
  if not saved then
    self._ui.notify("Voyager save failed: " .. tostring(reason or "unknown error"), vim.log.levels.ERROR)
    self:_remount_after_interaction(state)
    return nil
  end

  self:_render(state)
  if type(on_success) == "function" then
    on_success()
  end
  return true
end

function Session:_load_context(active)
  local runtime = self._runtime
  local context = {
    bufnr = runtime.current_buf(),
    winid = runtime.current_win(),
    tabpage = runtime.current_tabpage(),
  }
  if active and not self:_eligible_window(self._state, context.winid) then
    local source = self:choose_jump_window()
    if source then
      context.winid = source
      context.bufnr = runtime.win_buf(source)
    end
  end
  return context
end

function Session:_jump_loaded_current(state)
  local node = state.flow:location(state.flow.current_node_id)
  if not node then
    return false
  end
  return self:_jump_to_location(state, node.id, false)
end

function Session:_install_loaded_flow(candidate, project_root_value, config, locator, store, load_context)
  local old = self:is_active() and self._state or nil
  local previous_generation = old and old.generation or self._generation
  local current = candidate:location(candidate.current_node_id)
  local stale = current == nil
  if current then
    local stale_ok, stale_result = pcall(locator.is_stale, locator, current.location)
    stale = not stale_ok or stale_result == true
  end
  if stale then
    candidate:set_current(candidate.root.id)
  end

  local staged = self:_stage_state({
    phase = "active",
    generation = previous_generation + 1,
    config = config,
    flow = candidate,
    project_root = project_root_value,
    locator = locator,
    store = store,
    origin_buf = load_context.bufnr,
    origin_win = load_context.winid,
    tabpage = load_context.tabpage,
    source_windows = old and vim.deepcopy(old.source_windows) or nil,
  })
  local source_windows = {}
  for _, winid in ipairs(staged.source_windows) do
    if self:_eligible_window(staged, winid) then
      table.insert(source_windows, winid)
    end
  end
  if #source_windows == 0 and self:_eligible_window(staged, load_context.winid) then
    table.insert(source_windows, load_context.winid)
  end
  staged.source_windows = source_windows

  if old then
    old.sidebar:unmount({ owned = true })
  end
  local mounted, mount_reason = staged.sidebar:mount({
    tabpage = load_context.tabpage,
    focus = false,
  })
  if not mounted then
    mount_reason = mount_reason or "could not mount sidebar"
    staged.sidebar:unmount({ owned = true })
    if old then
      local restored = old.sidebar:mount({ tabpage = load_context.tabpage, focus = false })
      if restored then
        self:_render(old)
      end
    end
    self._ui.notify("Voyager load failed: " .. tostring(mount_reason), vim.log.levels.ERROR)
    return nil, mount_reason
  end

  if old then
    old.phase = "replacing"
    old.generation = staged.generation
    self:_invalidate_interactions(old)
    for _, handle in pairs(old.request_handles) do
      pcall(handle.cancel, handle, "load")
    end
    old.request_handles = {}
    old.request_count = 0
    self:_delete_autocmds(old)
  else
    self._interaction_counter = self._interaction_counter + 1
    self._interaction_tokens = {}
  end

  self._generation = staged.generation
  self._state = staged
  self:_register_autocmds(staged)
  self:_render(staged)
  self:_jump_loaded_current(staged)
  return true
end

function Session:load()
  local active = self:is_active()
  if active and self._state.phase ~= "active" then
    self:_lifecycle_busy("load")
    return nil
  end
  local load_context = self:_load_context(active)
  local project_root_value
  if active then
    project_root_value = self._state.project_root
  elseif self:_is_normal_named_buffer(load_context.bufnr) then
    local discovery = self._store_factory(nil)
    project_root_value = discovery:project_root(
      load_context.bufnr,
      self._runtime.get_clients({ bufnr = load_context.bufnr }),
      self._runtime.cwd()
    )
  else
    project_root_value = realpath(self._runtime, self._runtime.cwd())
  end

  local config = self._config_provider()
  local locator = self._locator_factory(project_root_value, config.storage.resolve_uri)
  local store = self._store_factory(locator)
  local listed, entries, warnings = pcall(store.list, store, project_root_value)
  if not listed then
    self._ui.notify("Voyager load failed: " .. tostring(entries), vim.log.levels.ERROR)
    return nil
  end
  entries = entries or {}
  for _, warning in ipairs(warnings or {}) do
    self._ui.notify(warning, vim.log.levels.WARN)
  end
  if #entries == 0 then
    self._ui.notify("Voyager: no saved flows for " .. project_root_value, vim.log.levels.INFO)
    return nil
  end

  local token = self:_replace_interaction_token("flow_picker")
  self._ui.select(entries, {
    prompt = "Load Voyager flow",
    format_item = function(entry)
      return string.format("%s — %s — %s", entry.name, entry.display_path, entry.updated_at)
    end,
  }, function(entry)
    if not self:_consume_interaction(token) or entry == nil then
      return
    end
    local function load_and_install()
      local loaded, candidate, load_error = pcall(store.load, store, entry, project_root_value)
      if not loaded then
        load_error = candidate
        candidate = nil
      end
      if not candidate then
        self._ui.notify("Voyager load failed: " .. tostring(load_error or "unknown error"), vim.log.levels.ERROR)
        return
      end
      return self:_install_loaded_flow(candidate, project_root_value, config, locator, store, load_context)
    end
    if self:is_active() and self._state.flow:is_dirty() then
      self:_decide_dirty("load", load_and_install)
    else
      load_and_install()
    end
  end)
  return true
end

function Session:_teardown(source)
  if not self:is_active() then
    return false
  end
  local state = self._state
  local previous_generation = state.generation
  local current_win = self._runtime.current_win()
  local owned_focus = state.sidebar:owns_window(current_win)
  local fallback = owned_focus and self:choose_jump_window() or nil
  state.phase = "closing"
  state.generation = previous_generation + 1
  self._generation = state.generation
  self:_invalidate_interactions(state)
  for _, handle in pairs(state.request_handles) do
    handle:cancel(source)
  end
  state.request_handles = {}
  state.request_count = 0
  self:_delete_autocmds(state)
  state.sidebar:unmount({ owned = true })
  if owned_focus and fallback and self._runtime.win_valid(fallback) then
    self._runtime.set_current_win(fallback)
  end
  state.phase = "closed"
  return true
end

function Session:close(source)
  if not self:is_active() then
    return false
  end
  local state = self._state
  if state.phase ~= "active" then
    self:_lifecycle_busy("close")
    return false
  end
  source = source or "close"
  if state.flow:is_dirty() then
    return self:_decide_dirty("close", function()
      self:_teardown(source)
    end)
  end
  return self:_teardown(source)
end

function Session:shutdown()
  return self:_teardown("shutdown")
end

function M.native(config_provider, runtime, overrides)
  local Store = require("voyager.store")
  local Schema = require("voyager.schema")
  local Flow = require("voyager.flow")
  local Sidebar = require("voyager.sidebar")
  local Actions = require("voyager.lsp.actions")
  local Normalize = require("voyager.lsp.normalize")
  local RequestGroup = require("voyager.lsp.request_group")
  local Lsp = require("voyager.lsp")

  local controller
  -- Every Voyager-originated client request is dispatched synchronously inside
  -- request_group.start, so this counter is what lets the LspRequest observer
  -- distinguish the user's navigation from Voyager's own recording traffic.
  local recording_request_group = {
    start = function(request_opts)
      controller._recording = controller._recording + 1
      local started, result = pcall(RequestGroup.start, request_opts)
      controller._recording = controller._recording - 1
      if not started then
        error(result, 0)
      end
      return result
    end,
  }

  local factories = vim.tbl_extend("force", {
    flow = Flow,
    locator = function(root_dir, resolve_uri)
      return Locator.new(runtime, root_dir, resolve_uri)
    end,
    store = function(locator)
      return Store.new({ runtime = runtime, schema = Schema, locator = locator, flow = Flow })
    end,
    sidebar = function(opts)
      return Sidebar.new(opts)
    end,
    lsp = function(locator, config)
      return Lsp.new({
        actions = Actions,
        normalizer = Normalize.new({ locator = locator }),
        request_group = recording_request_group,
        get_clients = runtime.get_clients,
        make_position_params = runtime.make_position_params,
        timer = runtime.timer,
        select = function(items, _, on_choice)
          local first = type(items) == "table" and items[1] or nil
          on_choice(first, first ~= nil and 1 or nil)
        end,
      })
    end,
  }, overrides or {})

  controller = M.new({
    config_provider = config_provider,
    runtime = runtime,
    flow = factories.flow,
    locator_factory = factories.locator,
    store_factory = factories.store,
    sidebar_factory = function(config)
      return factories.sidebar({
        sidebar = config.sidebar,
        keymaps = config.sidebar_keymaps,
        handlers = {
          activate = function(row)
            return controller:activate_row(row)
          end,
          note = function(row)
            return controller:edit_note(row)
          end,
          save = function()
            return controller:save()
          end,
          load = function()
            return controller:load()
          end,
          toggle = function(row)
            return controller:toggle_row(row)
          end,
          close = function()
            return controller:close("sidebar")
          end,
          external_close = function()
            return controller:close("external_popup")
          end,
        },
        notify = runtime.notify,
      })
    end,
    lsp_factory = factories.lsp,
    ui = { input = runtime.input, select = runtime.select, notify = runtime.notify },
  })
  return controller
end

return M
