local Locator = require("voyager.locator")
local Actions = require("voyager.lsp.actions")
local Recursive = require("voyager.recursive")

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

local function relation_key(origin_id, method)
  return "relation:" .. origin_id .. ":" .. method
end

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
    _symbols_factory = opts.symbols_factory,
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
  if not state.flow then
    return false
  end
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
    relation_requests = {},
    ordinary_relation_requests = {},
    relation_versions = {},
    directional_request_tokens = {},
    invalidated_request_tokens = {},
    relations = {},
    recursive = nil,
    recursive_token = 0,
    request_token = 0,
    interaction_token = 0,
    interaction_tokens = {},
    tracking_token = 0,
    destination_claim = nil,
    expanded_test_groups = {},
    observer_pending = {},
    current_claim_token = 0,
    manual_claim_token = 0,
    symbol_enrichments = {},
    symbol_enrichment_attempted = {},
    source_windows = vim.deepcopy(opts.source_windows or { opts.origin_win }),
    origin_buf = opts.origin_buf,
    origin_win = opts.origin_win,
    tabpage = opts.tabpage,
    locator = locator,
    store = store,
  }
  state.sidebar = self._sidebar_factory(config)
  state.lsp = self._lsp_factory(locator, config)
  state.symbols = self._symbols_factory and self._symbols_factory(locator, config) or nil
  return state
end

function Session:_uri_for_locator(state, locator)
  if locator.kind == "uri" then
    return locator.uri
  end
  local path = locator.kind == "project" and (state.project_root .. "/" .. locator.path) or locator.path
  local ok, uri = pcall(self._runtime.uri_from_fname, path)
  return ok and uri or nil
end

-- Ask the symbols service for enclosing-symbol names and kinds of freshly
-- committed nodes; results land asynchronously and only refine display
-- metadata, so failures stay silent behind the word-at fallback names.
function Session:_enrich_nodes(state, generation, flow_id, items)
  if not state.symbols then
    return
  end
  local requests = {}
  local seen = {}
  for _, item in ipairs(items) do
    local node_id = type(item) == "table" and item.node_id or item
    local node = type(node_id) == "string" and state.flow:location(node_id) or nil
    if
      node
      and node.location.query_anchor == nil
      and not seen[node.id]
      and state.symbol_enrichments[node.id] == nil
    then
      seen[node.id] = true
      state.symbol_enrichment_attempted[node.id] = true
      local uri = self:_uri_for_locator(state, node.location.locator)
      if uri then
        table.insert(requests, { node_id = node.id, uri = uri, location = vim.deepcopy(node.location) })
      end
    end
  end
  if #requests == 0 then
    return
  end

  for _, request in ipairs(requests) do
    state.symbol_enrichments[request.node_id] = { waiters = {} }
  end
  local settled = false
  local function finish(results)
    if settled then
      return
    end
    settled = true
    if not self:_valid_state(state, generation) or not state.flow or state.flow.flow_id ~= flow_id then
      return
    end
    results = type(results) == "table" and results or {}
    local changed = false
    local waiters = {}
    for _, request in ipairs(requests) do
      local node_id = request.node_id
      local entry = state.symbol_enrichments[node_id]
      local value = type(results[node_id]) == "table" and results[node_id] or {}
      local node = state.flow:location(node_id)
      local relation_active = false
      for _, action_name in ipairs({ "incoming_calls", "outgoing_calls" }) do
        local method = Actions.get(action_name).method
        local key = relation_key(node_id, method)
        if state.relation_requests[key] or state.relations[key] or state.flow:action_for(node_id, method) then
          relation_active = true
          break
        end
      end
      -- Keep the displayed token and its query subject aligned once the user
      -- has asked about either call direction. A late enclosing-symbol result
      -- must not relabel an in-flight or cached relationship after the query
      -- was issued from the provisional token.
      if
        node
        and node.location.query_anchor == nil
        and not relation_active
        and state.flow:apply_symbol(node_id, value.symbol, value.kind, value.query_anchor)
      then
        changed = true
      end
      state.symbol_enrichments[node_id] = nil
      for _, waiter in ipairs((entry and entry.waiters) or {}) do
        table.insert(waiters, waiter)
      end
    end
    if changed then
      self:_render(state)
    end
    for _, waiter in ipairs(waiters) do
      local called, waiter_error = pcall(waiter)
      if not called then
        self._ui.notify("Voyager: symbol waiter failed: " .. tostring(waiter_error), vim.log.levels.ERROR)
      end
    end
  end

  local called = pcall(state.symbols.resolve, state.symbols, requests, {
    timeout_ms = state.config.navigation.timeout_ms,
  }, finish)
  if not called then
    finish({})
  end
end

function Session:_await_symbol_enrichment(state, node_id, callback)
  local node = state.flow and state.flow:location(node_id) or nil
  if not node or node.id == state.flow.root.id or node.location.query_anchor ~= nil or not state.symbols then
    callback()
    return false
  end

  local pending = state.symbol_enrichments[node_id]
  if pending then
    table.insert(pending.waiters, callback)
    return true
  end
  if state.symbol_enrichment_attempted[node_id] then
    callback()
    return false
  end

  self:_enrich_nodes(state, state.generation, state.flow.flow_id, { node_id })
  pending = state.symbol_enrichments[node_id]
  if not pending then
    callback()
    return false
  end
  table.insert(pending.waiters, callback)
  return true
end

function Session:_render(state)
  local recursive
  if state.recursive then
    recursive = {
      seed_id = state.recursive.seed_id,
      method = state.recursive.method,
      direction = state.recursive.direction,
      state = state.recursive.state,
      processed = state.recursive.processed,
      scheduled = state.recursive.scheduled,
      max_subjects = state.recursive.max_subjects,
      allowance = state.recursive.allowance,
      depth = state.recursive.depth,
      max_depth = state.recursive.max_depth,
      active = state.recursive.active,
      issues = state.recursive.issues,
      truncated = state.recursive.truncated,
      paused = state.recursive.paused,
      cancelled = state.recursive.cancelled,
      message = state.recursive.message,
    }
  end
  state.sidebar:render(state.flow, {
    dirty = state.flow ~= nil and state.flow:is_dirty() or false,
    request_count = state.request_count,
    expanded_test_groups = state.expanded_test_groups,
    relations = state.relations,
    recursive = recursive,
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
  local action_name, action = Actions.by_method(request.method)
  if not action_name or action.internal == true then
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
  -- The flow (and its root record) is created lazily by the first observed
  -- LSP navigation, so opening only stages an empty session.
  local generation = math.max(self._generation, self._state and self._state.generation or 0) + 1
  local staged = self:_stage_state({
    generation = generation,
    config = config,
    flow = nil,
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

  if context.replace_targets == true and type(context.relation_version) == "number" then
    local key = relation_key(outcome.origin_node_id, outcome.method)
    if (state.relation_versions[key] or 0) ~= context.relation_version then
      return { commit = nil, tagged_items = {}, stale_relation = true }
    end
  end

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
    query_status = outcome.status == "partial" and "partial" or "complete",
    replace_targets = context.replace_targets == true and outcome.status ~= "partial",
  })
  local committed_key = relation_key(commit.effective_origin_id, outcome.method)
  state.relation_versions[committed_key] = (state.relation_versions[committed_key] or 0) + 1
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
  if state.recursive then
    self:_guard_recursive_relations(state)
  end
  return { commit = commit, tagged_items = tagged_items }
end

-- The starting record is captured from the origin of the first navigation,
-- not from the cursor at :VoyagerOpen time.
function Session:_create_flow(state, bufnr, winid)
  local runtime = self._runtime
  local root, root_error = Locator.capture_root(bufnr, winid, state.project_root, runtime)
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
  state.flow = self._flow_module.new({
    root = root,
    name = Locator.flow_name(root),
    flow_id = flow_id,
    root_key = Locator.root_key(root),
    now = runtime.now,
    next_id = Locator.id_factory(flow_id, nonce, 0, runtime.sha256),
  })
  self:_render(state)
  self:_enrich_nodes(state, state.generation, flow_id, { state.flow.root.id })
  return true
end

function Session:ensure_flow()
  if not self:is_active() then
    return nil
  end
  local state = self._state
  if state.flow then
    return true
  end
  local winid = self._runtime.current_win()
  if not self:_eligible_window(state, winid) then
    self._ui.notify("Voyager: navigation requires an eligible source window", vim.log.levels.WARN)
    return nil
  end
  return self:_create_flow(state, self._runtime.win_buf(winid), winid)
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
  local winid = self._runtime.current_win()
  if not self:_eligible_window(state, winid) then
    self._ui.notify("Voyager: navigation requires an eligible source window", vim.log.levels.WARN)
    return nil
  end
  local bufnr = self._runtime.win_buf(winid)
  if not state.flow and not self:_create_flow(state, bufnr, winid) then
    return nil
  end
  local flow_id = state.flow.flow_id
  local context, context_error = self:_action_context(state, winid, bufnr)
  if not context then
    self._ui.notify("Voyager: could not capture navigation origin: " .. tostring(context_error), vim.log.levels.ERROR)
    return nil
  end

  local ordinary_relation_key
  if action_name == "incoming_calls" or action_name == "outgoing_calls" then
    local relation_origin_id = context.origin_node_id
    if context.manual_location then
      relation_origin_id = nil
      local identity = context.manual_location.identity or Locator.location_key(context.manual_location)
      for _, node in ipairs(state.flow:dfs()) do
        if node.kind == "location" and Locator.location_key(node.location) == identity then
          relation_origin_id = node.id
          break
        end
      end
    end
    if relation_origin_id then
      ordinary_relation_key = relation_key(relation_origin_id, action.method)
    end
  end

  state.request_token = state.request_token + 1
  local request_token = state.request_token
  context.request_token = request_token
  state.tracking_token = request_token
  state.destination_claim = nil
  state.current_claim_token = request_token
  state.manual_claim_token = context.manual_location and request_token or 0
  if ordinary_relation_key then
    local requests = state.ordinary_relation_requests[ordinary_relation_key] or {}
    requests[request_token] = true
    state.ordinary_relation_requests[ordinary_relation_key] = requests
  end

  local older_handles = {}
  for token, handle in pairs(state.request_handles) do
    if not state.directional_request_tokens[token] then
      table.insert(older_handles, handle)
    end
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

    if state.invalidated_request_tokens[request_token] then
      state.invalidated_request_tokens[request_token] = nil
      return
    end
    if ordinary_relation_key then
      local requests = state.ordinary_relation_requests[ordinary_relation_key]
      if requests then
        requests[request_token] = nil
        if next(requests) == nil then
          state.ordinary_relation_requests[ordinary_relation_key] = nil
        end
      end
    end

    state.request_handles[request_token] = nil
    assert(state.request_count > 0, "Voyager request counter underflow")
    state.request_count = state.request_count - 1

    local tagged_items
    if type(outcome) == "table" and committing_statuses[outcome.status] then
      local commit_ok, commit_result = pcall(self._commit_outcome, self, state, context, request_token, outcome)
      if commit_ok then
        tagged_items = commit_result.tagged_items
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
    then
      if state.tracking_token == request_token then
        self:_arm_destination_claim(state, context, tagged_items)
      end
      self:_enrich_nodes(state, generation, flow_id, tagged_items)
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
  if not state.flow or not state.flow:location(node_id) then
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
        end_lnum = list_item.end_lnum,
        end_col = list_item.end_col,
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
  local function target_in_buffer(target)
    if type(target.bufnr) == "number" then
      return target.bufnr == bufnr
    end
    if type(target.filename) ~= "string" then
      return false
    end
    buffer_path = buffer_path or realpath(runtime, runtime.buffer_name(bufnr))
    return buffer_path == realpath(runtime, target.filename)
  end

  -- Pickers do not all land on the exact column (some jump to the line
  -- start), so accept a containment or unique same-line match as well.
  local exact
  local contained
  local on_line = {}
  for _, target in ipairs(claim.targets) do
    if cursor.line == target.lnum - 1 and target_in_buffer(target) then
      table.insert(on_line, target)
      if cursor.character == target.col - 1 then
        exact = exact or target
      elseif
        target.end_lnum == target.lnum
        and type(target.end_col) == "number"
        and cursor.character >= target.col - 1
        and cursor.character < target.end_col - 1
      then
        contained = contained or target
      end
    end
  end
  local chosen = exact or contained or (#on_line == 1 and on_line[1] or nil)
  if chosen then
    self:_make_current(state, chosen.node_id)
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
    local state_flow_id = state.flow and state.flow.flow_id or nil
    return state.generation == token.generation and state_flow_id == token.flow_id
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
  if self._state ~= state or not self:is_active() or not state.flow then
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
  self._runtime.flash_line(target.bufnr, target.row)
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

function Session:activate_row(row, opts)
  if not self:is_active() then
    return false
  end
  if type(row) ~= "table" or type(row.owner_id) ~= "string" then
    self:_notify_inapplicable("activate", row)
    return false
  end
  if row.kind == "action" or row.kind == "group" then
    return self:toggle_row(row)
  end
  if row.kind ~= "location" and row.kind ~= "note" then
    self:_notify_inapplicable("activate", row)
    return false
  end
  local state = self._state
  local jumped = self:_jump_to_location(state, row.owner_id, true)
  if jumped and type(opts) == "table" and opts.stay then
    state.sidebar:focus()
  end
  return jumped
end

function Session:toggle_row(row)
  if not self:is_active() then
    return false
  end
  if type(row) == "table" and row.kind == "group" then
    return self:toggle_test_group(row)
  end
  local flow = self._state.flow
  local node = type(row) == "table" and flow and flow:find(row.owner_id) or nil
  if type(row) ~= "table" or row.kind ~= "action" or not node or node.kind ~= "action" then
    self:_notify_inapplicable("toggle", row)
    return false
  end
  local changed = flow:toggle(row.owner_id)
  if changed then
    self:_render(self._state)
  end
  return changed
end

function Session:toggle_test_group(row)
  if not self:is_active() then
    return false
  end
  local state = self._state
  if type(row) ~= "table" or row.kind ~= "group" or type(row.owner_id) ~= "string" then
    self:_notify_inapplicable("toggle", row)
    return false
  end
  state.expanded_test_groups[row.owner_id] = not state.expanded_test_groups[row.owner_id] or nil
  self:_render(state)
  return true
end

function Session:_row_location_id(row)
  if type(row) ~= "table" then
    return nil
  end
  if type(row.context_location_id) == "string" then
    return row.context_location_id
  end
  if type(row.owner_id) ~= "string" then
    return nil
  end
  if row.kind == "location" or row.kind == "note" then
    return row.owner_id
  end
  if row.kind == "action" or row.kind == "group" then
    return self._state.flow and self._state.flow:parent_id(row.owner_id) or nil
  end
end

function Session:_stored_action_context(state, origin_id)
  local node = state.flow and state.flow:location(origin_id) or nil
  if not node then
    return nil, "location is no longer available"
  end

  -- A row can jump to a recorded occurrence while representing its enclosing
  -- symbol or a call-hierarchy caller/callee. Newer records persist that
  -- subject's selection range separately; legacy documents have no anchor and
  -- continue to query from the display location.
  local anchor = type(node.location.query_anchor) == "table" and node.location.query_anchor or node.location
  local query_location = anchor == node.location and node.location
    or { locator = vim.deepcopy(anchor.locator), range = vim.deepcopy(anchor.range) }

  -- Resolving/loading a target is intentionally separate from displaying it:
  -- this gives LSP a real buffer without changing any source window, cursor,
  -- or Voyager's logical current node.
  local opened, target, target_error = pcall(state.locator.open_target, state.locator, query_location, { list = false })
  if not opened then
    return nil, target
  end
  if not target then
    return nil, target_error or "source is unavailable"
  end
  local uri = self:_uri_for_locator(state, anchor.locator)
  if not uri then
    return nil, "location URI is unavailable"
  end

  local read, lines = pcall(self._runtime.get_buffer_lines, target.bufnr)
  if not read or type(lines) ~= "table" then
    return nil, read and "source lines are unavailable" or lines
  end
  local start = anchor.range and anchor.range.start or nil
  if type(start) ~= "table" or type(start.line) ~= "number" or type(start.character) ~= "number" then
    return nil, "stored location position is invalid"
  end
  local line_text = lines[start.line + 1]
  if type(line_text) ~= "string" then
    return nil, "stored location line is unavailable"
  end
  if anchor ~= node.location and line_text ~= anchor.line_text then
    return nil, "stored symbol query anchor changed"
  end

  return {
    generation = state.generation,
    flow_id = state.flow.flow_id,
    origin_node_id = origin_id,
    bufnr = target.bufnr,
    project_root = state.project_root,
    timeout_ms = state.config.navigation.timeout_ms,
    directional = true,
    stored_position = {
      uri = uri,
      line = start.line,
      character = start.character,
      line_text = line_text,
      encoding = "utf-8",
    },
  }
end

local function relation_error_message(outcome)
  local failure = first_failure_message(outcome)
  if failure then
    return failure
  end
  if outcome.status == "timeout" then
    return "timed out"
  end
  if outcome.status == "unsupported" then
    return "not supported"
  end
  if outcome.status == "cancelled" then
    return "cancelled"
  end
  if outcome.status == "superseded" then
    return "superseded"
  end
  return "request failed"
end

local function relation_result(state, pending, status, outcome)
  local persisted = state.flow and state.flow:action_for(pending.origin_id, pending.method) or nil
  local target_ids = persisted and state.flow:action_target_ids(persisted) or {}
  local locations = {}
  for _, target_id in ipairs(target_ids) do
    local target = state.flow:location(target_id)
    if target then
      table.insert(locations, vim.deepcopy(target.location))
    end
  end
  return {
    status = status,
    action = vim.deepcopy(persisted or pending.action),
    action_id = persisted and persisted.id or nil,
    origin_id = pending.origin_id,
    method = pending.method,
    label = pending.label,
    target_ids = target_ids,
    locations = locations,
    failures = vim.deepcopy(type(outcome) == "table" and outcome.failures or {}),
    message = type(outcome) == "table"
        and not committing_statuses[status]
        and status ~= "cached"
        and relation_error_message(outcome)
      or nil,
  }
end

function Session:_call_relation_listener(listener, result)
  if type(listener) ~= "function" then
    return
  end
  local called, callback_error = pcall(listener, vim.deepcopy(result))
  if not called then
    self._ui.notify("Voyager: relation listener failed: " .. tostring(callback_error), vim.log.levels.ERROR)
  end
end

function Session:_deliver_relation_listeners(pending, result)
  local listeners = pending.listeners or {}
  pending.listeners = {}
  pending.owners = {}
  for _, entry in ipairs(listeners) do
    self:_call_relation_listener(entry.callback, result)
  end
end

function Session:_attach_relation_consumer(pending, opts)
  opts = opts or {}
  if opts.owner == nil then
    pending.manual = true
    pending.notify = opts.notify ~= false
    pending.expand = opts.expand ~= false
  else
    pending.owners = pending.owners or {}
    pending.owners[opts.owner] = true
  end
  if type(opts.listener) == "function" then
    pending.listeners = pending.listeners or {}
    table.insert(pending.listeners, { owner = opts.owner, callback = opts.listener })
  end
end

function Session:_cancel_pending_relation(state, key, pending, reason, deliver)
  if state.relation_requests[key] ~= pending then
    return false
  end
  local request_token = pending.request_token
  local handle = pending.handle or state.request_handles[request_token]
  state.relation_requests[key] = nil
  state.directional_request_tokens[request_token] = nil
  state.request_handles[request_token] = nil
  assert(state.request_count > 0, "Voyager request counter underflow")
  state.request_count = state.request_count - 1
  state.relations[key] = nil
  if deliver then
    self:_deliver_relation_listeners(
      pending,
      relation_result(state, pending, "cancelled", {
        status = "cancelled",
        failures = { { kind = "cancelled", message = tostring(reason or "cancelled") } },
      })
    )
  else
    pending.listeners = {}
    pending.owners = {}
  end
  if type(handle) == "table" and type(handle.cancel) == "function" then
    pcall(handle.cancel, handle, reason or "cancelled")
  end
  return true
end

function Session:_detach_relation_owner(state, owner, reason)
  if owner == nil then
    return false
  end
  local cancelled = {}
  local detached = false
  for key, pending in pairs(state.relation_requests) do
    local listeners = {}
    local removed = false
    for _, entry in ipairs(pending.listeners or {}) do
      if entry.owner == owner then
        removed = true
      else
        table.insert(listeners, entry)
      end
    end
    if pending.owners and pending.owners[owner] then
      pending.owners[owner] = nil
      removed = true
    end
    if removed then
      detached = true
      pending.listeners = listeners
      if not pending.manual and next(pending.owners or {}) == nil and #listeners == 0 then
        table.insert(cancelled, { key = key, pending = pending })
      end
    end
  end
  for _, entry in ipairs(cancelled) do
    self:_cancel_pending_relation(state, entry.key, entry.pending, reason or "consumer cancelled", false)
  end
  return detached
end

function Session:show_relation(row, action_name, opts)
  opts = type(opts) == "table" and opts or {}
  if not self:is_active() then
    return nil
  end
  local state = self._state
  if not state.flow then
    self:_notify_inapplicable("show a call relation", row)
    return nil
  end

  local origin_id = self:_row_location_id(row)
  local origin = origin_id and state.flow:location(origin_id) or nil
  if not origin then
    self:_notify_inapplicable("show a call relation", row)
    return nil
  end

  local action_ok, action = pcall(Actions.get, action_name)
  if not action_ok or (action_name ~= "incoming_calls" and action_name ~= "outgoing_calls") then
    self._ui.notify("Voyager: invalid call relation", vim.log.levels.ERROR)
    return nil
  end

  local key = relation_key(origin_id, action.method)
  local transient = state.relations[key]
  local force = opts.refresh == true
  if transient and transient.state == "error" and transient.replace_targets == true then
    force = true
  end
  local cached = state.flow:action_for(origin_id, action.method)
  local retry_partial = opts.retry_partial == true and cached and cached.query_status == "partial"
  local focus = opts.focus ~= false
  local expand = opts.expand ~= false
  local manual = opts.owner == nil

  -- Repeated lowercase/uppercase commands coalesce on the same logical
  -- relation while still bringing its stable row back into view.
  local pending = state.relation_requests[key]
  if pending then
    if force then
      if (state.relation_versions[key] or 0) ~= pending.relation_version then
        self:_invalidate_relation(state, origin_id, action.method, "refresh")
        return self:show_relation(row, action_name, opts)
      end
      pending.replace_targets = true
      if state.relations[key] then
        state.relations[key].replace_targets = true
      end
    end
    self:_attach_relation_consumer(pending, opts)
    if manual and not state.relations[key] then
      state.relations[key] = {
        key = key,
        origin_id = origin_id,
        method = action.method,
        label = action.label,
        state = "loading",
        replace_targets = pending.replace_targets == true,
      }
      self:_render(state)
    end
    if focus then
      state.sidebar:focus_relation(origin_id, action.method)
    end
    return pending.handle or true
  end

  if cached and not force and not retry_partial and not (transient and transient.state == "error") then
    local had_transient = state.relations[key] ~= nil
    state.relations[key] = nil
    local expanded = expand and state.flow:set_collapsed(cached.id, false) or false
    if expanded or had_transient then
      self:_render(state)
    end
    if focus then
      state.sidebar:focus_relation(origin_id, action.method)
    end
    self:_call_relation_listener(
      opts.listener,
      relation_result(state, {
        action = action,
        origin_id = origin_id,
        method = action.method,
        label = action.label,
      }, "cached")
    )
    return true
  end

  if cached and expand then
    state.flow:set_collapsed(cached.id, false)
  end

  state.request_token = state.request_token + 1
  local request_token = state.request_token
  pending = {
    request_token = request_token,
    origin_id = origin_id,
    method = action.method,
    label = action.label,
    action = action,
    replace_targets = force,
    relation_version = state.relation_versions[key] or 0,
    listeners = {},
    owners = {},
    manual = false,
    notify = false,
    expand = false,
  }
  self:_attach_relation_consumer(pending, opts)
  state.relation_requests[key] = pending
  if pending.manual then
    state.relations[key] = {
      key = key,
      origin_id = origin_id,
      method = action.method,
      label = action.label,
      state = "loading",
      replace_targets = force,
    }
  end
  state.directional_request_tokens[request_token] = true
  state.request_count = state.request_count + 1
  self:_render(state)
  if focus then
    state.sidebar:focus_relation(origin_id, action.method)
  end

  local context, context_error = self:_stored_action_context(state, origin_id)
  if not context then
    state.relation_requests[key] = nil
    state.directional_request_tokens[request_token] = nil
    assert(state.request_count > 0, "Voyager request counter underflow")
    state.request_count = state.request_count - 1
    if pending.manual then
      state.relations[key] = {
        key = key,
        origin_id = origin_id,
        method = action.method,
        label = action.label,
        state = "error",
        message = tostring(context_error),
        replace_targets = force,
      }
    else
      state.relations[key] = nil
    end
    self:_render(state)
    local failed = {
      status = "error",
      failures = { { kind = "setup", message = tostring(context_error) } },
    }
    if pending.notify then
      self._ui.notify("Voyager: " .. action.label .. " failed: " .. tostring(context_error), vim.log.levels.ERROR)
    end
    self:_deliver_relation_listeners(pending, relation_result(state, pending, "error", failed))
    return nil
  end
  context.request_token = request_token
  context.replace_targets = force
  context.relation_version = state.relation_requests[key].relation_version

  local generation = state.generation
  local flow_id = state.flow.flow_id
  local settled = false
  local function settle(outcome)
    if settled then
      return
    end
    settled = true
    if not self:_valid_state(state, generation) or not state.flow or state.flow.flow_id ~= flow_id then
      return
    end

    local current = state.relation_requests[key]
    if not current or current.request_token ~= request_token then
      return
    end
    pending = current
    local replacement_intent = pending.replace_targets == true
    local stale_relation = replacement_intent and (state.relation_versions[key] or 0) ~= pending.relation_version
    context.replace_targets = replacement_intent
    context.relation_version = pending.relation_version
    state.relation_requests[key] = nil
    state.directional_request_tokens[request_token] = nil
    state.request_handles[request_token] = nil
    assert(state.request_count > 0, "Voyager request counter underflow")
    state.request_count = state.request_count - 1

    if stale_relation then
      state.relations[key] = nil
      self:_render(state)
      self:_deliver_relation_listeners(
        pending,
        relation_result(state, pending, "superseded", {
          status = "superseded",
          failures = {},
        })
      )
      return
    end

    outcome = type(outcome) == "table" and outcome
      or {
        status = "error",
        label = action.label,
        method = action.method,
        origin_node_id = origin_id,
        failures = { { kind = "setup", message = "invalid LSP completion" } },
      }

    local commit_result
    if committing_statuses[outcome.status] then
      local commit_ok, value = pcall(self._commit_outcome, self, state, context, request_token, outcome)
      if commit_ok then
        state.relations[key] = nil
        if not value.stale_relation then
          commit_result = value
          if pending.expand then
            state.flow:set_collapsed(value.commit.action_id, false)
          end
          if pending.notify then
            self:_notify_outcome(outcome)
          end
        end
      else
        outcome = {
          status = "error",
          action = action,
          method = action.method,
          label = action.label,
          origin_node_id = origin_id,
          failures = { { kind = "commit", message = tostring(value) } },
        }
        if pending.manual then
          state.relations[key] = {
            key = key,
            origin_id = origin_id,
            method = action.method,
            label = action.label,
            state = "error",
            message = tostring(value),
            replace_targets = replacement_intent,
          }
        else
          state.relations[key] = nil
        end
        if pending.notify then
          self._ui.notify("Voyager: " .. action.label .. " failed: " .. tostring(value), vim.log.levels.ERROR)
        end
      end
    elseif outcome.status == "cancelled" or outcome.status == "superseded" then
      state.relations[key] = nil
      if pending.notify then
        self:_notify_outcome(outcome)
      end
    else
      if pending.manual then
        state.relations[key] = {
          key = key,
          origin_id = origin_id,
          method = action.method,
          label = action.label,
          state = "error",
          message = relation_error_message(outcome),
          replace_targets = replacement_intent,
        }
      else
        state.relations[key] = nil
      end
      if pending.notify then
        self:_notify_outcome(outcome)
      end
    end

    -- Rendering preserves the user's current stable row. Only the immediate
    -- key command above focuses the relation; asynchronous completion never
    -- moves the cursor or steals a window.
    self:_render(state)
    if commit_result and #commit_result.tagged_items > 0 then
      self:_enrich_nodes(state, generation, flow_id, commit_result.tagged_items)
    end
    self:_deliver_relation_listeners(pending, relation_result(state, pending, outcome.status, outcome))
  end

  local started, handle = pcall(state.lsp.start, state.lsp, action_name, vim.deepcopy(context), settle)
  if not started then
    settle({
      status = "error",
      action = action,
      method = action.method,
      label = action.label,
      origin_node_id = origin_id,
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
      origin_node_id = origin_id,
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
  if not settled and done then
    settle({
      status = "error",
      action = action,
      method = action.method,
      label = action.label,
      origin_node_id = origin_id,
      items = {},
      locations = {},
      failures = { { kind = "setup", message = "LSP request completed without an outcome" } },
    })
  end
  if
    not settled
    and self:_valid_state(state, generation)
    and state.flow.flow_id == flow_id
    and state.relation_requests[key]
    and not done
  then
    state.relation_requests[key].handle = handle
    state.request_handles[request_token] = handle
  end
  return handle
end

function Session:show_callers(row, refresh)
  return self:show_relation(row, "incoming_calls", { refresh = refresh == true })
end

function Session:show_callees(row, refresh)
  return self:show_relation(row, "outgoing_calls", { refresh = refresh == true })
end

local recursive_directions = {
  callers = { action_name = "incoming_calls", direction = "callers" },
  incoming_calls = { action_name = "incoming_calls", direction = "callers" },
  callees = { action_name = "outgoing_calls", direction = "callees" },
  outgoing_calls = { action_name = "outgoing_calls", direction = "callees" },
}

local recursive_ok_statuses = {
  cached = true,
  success = true,
  empty = true,
}

local recursive_target_statuses = vim.tbl_extend("force", vim.deepcopy(recursive_ok_statuses), { partial = true })

local recursive_bounds = {
  depth = { 1, 10 },
  max_subjects = { 1, 1000 },
  concurrency = { 1, 16 },
}

local function recursive_option(name, value)
  local bounds = recursive_bounds[name]
  if type(value) ~= "number" or value % 1 ~= 0 or value < bounds[1] or value > bounds[2] then
    return nil, string.format("%s must be an integer from %d through %d", name, bounds[1], bounds[2])
  end
  return value
end

function Session:_focus_recursive(state, record)
  if type(state.sidebar.focus_recursive) == "function" then
    return state.sidebar:focus_recursive(record.seed_id, record.method)
  end
  return state.sidebar:focus_relation(record.seed_id, record.method)
end

function Session:_sync_recursive_status(record)
  local status = record.scheduler:status()
  record.processed = status.processed
  record.scheduled = status.scheduled
  record.max_subjects = status.max_subjects
  record.allowance = status.allowance
  record.depth = status.depth
  record.max_depth = status.max_depth
  record.active = status.active
  record.issues = status.issues
  record.truncated = status.truncated
  record.paused = status.paused
  record.cancelled = status.cancelled
  return status
end

local function recursive_subject_snapshot(node)
  if not node then
    return { present = false }
  end
  local location = node.location
  local anchor = type(location.query_anchor) == "table" and location.query_anchor or location
  return {
    present = true,
    anchored = anchor ~= location,
    locator = vim.deepcopy(anchor.locator),
    range = vim.deepcopy(anchor.range),
    line_text = anchor.line_text,
  }
end

local function recursive_relation_snapshot(flow, origin_id, method)
  local action = flow and flow:action_for(origin_id, method) or nil
  local target_ids = action and flow:action_target_ids(action) or {}
  table.sort(target_ids)
  return {
    present = action ~= nil,
    query_status = action and action.query_status or nil,
    target_ids = target_ids,
  }
end

function Session:_recursive_relations_unchanged(state, record)
  for origin_id, expected in pairs(record.subject_snapshots or {}) do
    if not vim.deep_equal(expected, recursive_subject_snapshot(state.flow:location(origin_id))) then
      return false
    end
  end
  for origin_id, expected in pairs(record.relation_snapshots or {}) do
    if not vim.deep_equal(expected, recursive_relation_snapshot(state.flow, origin_id, record.method)) then
      return false
    end
  end
  return true
end

function Session:_guard_recursive_relations(state)
  local record = state.recursive
  if
    not record
    or (record.state ~= "running" and record.state ~= "paused")
    or self:_recursive_relations_unchanged(state, record)
  then
    return true
  end

  self:cancel_build({ dismiss = false, silent = true, render = false, reason = "flow changed" })
  record.state = "issues"
  record.message = "flow changed during the build; run it again to continue"
  self:_render(state)
  self._ui.notify("Voyager: recursive build stopped because the flow changed; run it again", vim.log.levels.WARN)
  return false
end

function Session:_update_recursive(state, record)
  if self._state ~= state or state.recursive ~= record then
    return true
  end
  if not self:_guard_recursive_relations(state) then
    return true
  end
  local status = self:_sync_recursive_status(record)
  if status.cancelled then
    record.state = "cancelled"
    record.message = record.message or "cancelled"
    self:_render(state)
    return true
  end
  if record.scheduler:is_done() then
    if status.issues > 0 then
      record.state = "issues"
      record.message = string.format("completed with %d issue%s", status.issues, status.issues == 1 and "" or "s")
      self:_render(state)
      if not record.terminal_notified then
        record.terminal_notified = true
        self._ui.notify(
          string.format(
            "Voyager: recursive %s build completed with %d issue%s",
            record.direction,
            status.issues,
            status.issues == 1 and "" or "s"
          ),
          vim.log.levels.WARN
        )
      end
    else
      state.recursive = nil
      self:_render(state)
      self._ui.notify(
        string.format("Voyager: recursive %s build completed (%d subjects)", record.direction, status.processed),
        vim.log.levels.INFO
      )
    end
    return true
  end
  if status.paused and status.active == 0 then
    record.state = "paused"
    record.message = string.format("subject limit reached at %d; run again to continue", status.allowance)
    if record.pause_notified_allowance ~= status.allowance then
      record.pause_notified_allowance = status.allowance
      self._ui.notify("Voyager: recursive build paused; run the same build again to continue", vim.log.levels.INFO)
    end
  else
    record.state = "running"
    record.message = nil
  end
  self:_render(state)
  return false
end

function Session:_schedule_recursive_pump(state, record)
  if self._state ~= state or state.recursive ~= record or record.pump_scheduled or record.state ~= "running" then
    return
  end
  record.pump_scheduled = true
  self._runtime.schedule(function()
    record.pump_scheduled = false
    if self:_valid_state(state, state.generation) and state.recursive == record and record.state == "running" then
      self:_pump_recursive(state, record)
    end
  end)
end

function Session:_pump_recursive(state, record)
  if self._state ~= state or state.recursive ~= record or record.state ~= "running" then
    return
  end
  if not self:_guard_recursive_relations(state) then
    return
  end

  local claimed = 0
  while claimed < record.batch_size do
    local item = record.scheduler:claim()
    if not item then
      break
    end
    claimed = claimed + 1
    local delivered = false
    local function complete(result)
      if delivered then
        return
      end
      delivered = true
      if self._state ~= state or state.recursive ~= record then
        return
      end
      if not self:_guard_recursive_relations(state) then
        return
      end
      result = type(result) == "table" and result or { status = "error", target_ids = {} }
      local may_use_cached_targets = result.status ~= "cancelled"
        and result.status ~= "superseded"
        and type(result.action_id) == "string"
      local targets = (recursive_target_statuses[result.status] or may_use_cached_targets)
          and type(result.target_ids) == "table"
          and result.target_ids
        or {}
      local issue = not recursive_ok_statuses[result.status]
      record.relation_snapshots[item.subject_id] =
        recursive_relation_snapshot(state.flow, item.subject_id, record.method)
      if record.scheduler:complete(item, targets, issue) then
        if not self:_update_recursive(state, record) then
          self:_schedule_recursive_pump(state, record)
        end
      end
    end

    self:_await_symbol_enrichment(state, item.subject_id, function()
      if self._state ~= state or state.recursive ~= record or record.state ~= "running" then
        return
      end
      if not self:_guard_recursive_relations(state) then
        return
      end
      record.subject_snapshots[item.subject_id] = recursive_subject_snapshot(state.flow:location(item.subject_id))
      local called, started = pcall(
        self.show_relation,
        self,
        {
          kind = "location",
          owner_id = item.subject_id,
          context_location_id = item.subject_id,
        },
        item.action_name,
        {
          focus = false,
          expand = false,
          retry_partial = true,
          notify = false,
          owner = record.owner,
          listener = complete,
        }
      )
      if not called then
        complete({
          status = "error",
          target_ids = {},
          failures = { { kind = "setup", message = tostring(started) } },
        })
      elseif started == nil and not delivered then
        complete({
          status = "error",
          target_ids = {},
          failures = { { kind = "setup", message = "relation request did not start" } },
        })
      end
    end)
  end

  if self._state ~= state or state.recursive ~= record then
    return
  end
  if self:_update_recursive(state, record) then
    return
  end
  local status = record.scheduler:status()
  if claimed >= record.batch_size and status.active < record.concurrency and not status.paused then
    self:_schedule_recursive_pump(state, record)
  end
end

function Session:start_recursive(row, direction, opts)
  opts = type(opts) == "table" and opts or {}
  if not self:is_active() then
    self._ui.notify("Voyager: no active flow", vim.log.levels.INFO)
    return nil
  end
  local state = self._state
  if not state.flow then
    self:_notify_inapplicable("build a recursive call flow", row)
    return nil
  end
  local seed_id = self:_row_location_id(row)
  if not seed_id or not state.flow:location(seed_id) then
    self:_notify_inapplicable("build a recursive call flow", row)
    return nil
  end

  local config = type(state.config.navigation.recursive) == "table" and state.config.navigation.recursive or {}
  local normalized = recursive_directions[direction or config.direction or "callees"]
  if not normalized then
    self._ui.notify("Voyager: recursive direction must be 'callers' or 'callees'", vim.log.levels.ERROR)
    return nil
  end
  local action = Actions.get(normalized.action_name)
  local current = state.recursive
  local same_subject = current and current.seed_id == seed_id and current.method == action.method
  local depth_value = opts.depth == nil and (same_subject and current.max_depth or config.depth or 3) or opts.depth
  local subjects_value = opts.max_subjects == nil
      and (same_subject and current.max_subjects or config.max_subjects or 32)
    or opts.max_subjects
  local concurrency_value = opts.concurrency == nil
      and (same_subject and current.concurrency or config.concurrency or 4)
    or opts.concurrency
  local depth, depth_error = recursive_option("depth", depth_value)
  local max_subjects, subjects_error = recursive_option("max_subjects", subjects_value)
  local concurrency, concurrency_error = recursive_option("concurrency", concurrency_value)
  local option_error = depth_error or subjects_error or concurrency_error
  if option_error then
    self._ui.notify("Voyager: recursive " .. option_error, vim.log.levels.ERROR)
    return nil
  end
  local same = current
    and current.seed_id == seed_id
    and current.method == action.method
    and current.max_depth == depth
    and current.max_subjects == max_subjects
    and current.concurrency == concurrency
  local focus = opts.focus ~= false
  if current and (current.state == "running" or current.state == "paused") then
    if same and current.state == "paused" then
      if self:_guard_recursive_relations(state) and current.scheduler:resume() then
        current.state = "running"
        current.message = nil
        self:_sync_recursive_status(current)
        self:_render(state)
        if focus then
          self:_focus_recursive(state, current)
        end
        self:_schedule_recursive_pump(state, current)
        return current.scheduler
      end
    end
    if focus then
      self:_focus_recursive(state, current)
    end
    if not same then
      self._ui.notify("Voyager: another recursive build is already active", vim.log.levels.WARN)
    end
    return same and current.scheduler or nil
  end
  if current then
    self:cancel_build({ dismiss = true, silent = true, reason = "replaced" })
  end

  local create_ok, scheduler = pcall(Recursive.new, {
    seed_id = seed_id,
    action_name = normalized.action_name,
    max_depth = depth,
    max_subjects = max_subjects,
    concurrency = concurrency,
  })
  if not create_ok then
    self._ui.notify("Voyager: could not start recursive build: " .. tostring(scheduler), vim.log.levels.ERROR)
    return nil
  end

  state.recursive_token = state.recursive_token + 1
  local status = scheduler:status()
  local record = {
    owner = string.format("recursive:%d:%d", state.generation, state.recursive_token),
    scheduler = scheduler,
    seed_id = seed_id,
    action_name = normalized.action_name,
    method = action.method,
    direction = normalized.direction,
    state = "running",
    processed = status.processed,
    scheduled = status.scheduled,
    max_subjects = status.max_subjects,
    allowance = status.allowance,
    depth = status.depth,
    max_depth = status.max_depth,
    active = status.active,
    issues = status.issues,
    truncated = status.truncated,
    paused = status.paused,
    cancelled = status.cancelled,
    concurrency = concurrency,
    relation_snapshots = {},
    subject_snapshots = {},
  }
  record.batch_size = math.max(1, math.min(32, record.concurrency * 4))
  state.recursive = record
  self:_render(state)
  if focus then
    self:_focus_recursive(state, record)
  end
  self:_schedule_recursive_pump(state, record)
  return scheduler
end

function Session:build(opts)
  opts = type(opts) == "table" and opts or {}
  if not self:is_active() then
    self._ui.notify("Voyager: no active flow", vim.log.levels.INFO)
    return nil
  end
  local state = self._state
  local row
  local from_sidebar = state.sidebar:owns_window(self._runtime.current_win())
  if type(opts.origin_id) == "string" then
    if not state.flow and not self:ensure_flow() then
      return nil
    end
    row = { kind = "location", owner_id = opts.origin_id, context_location_id = opts.origin_id }
  elseif from_sidebar then
    row = type(state.sidebar.selected_row) == "function" and state.sidebar:selected_row() or nil
  else
    if not self:ensure_flow() then
      return nil
    end
    row = {
      kind = "location",
      owner_id = state.flow.current_node_id,
      context_location_id = state.flow.current_node_id,
    }
  end
  local config = type(state.config.navigation.recursive) == "table" and state.config.navigation.recursive or {}
  local start_opts = vim.deepcopy(opts)
  start_opts.focus = from_sidebar
  return self:start_recursive(row, opts.direction or config.direction or "callees", start_opts)
end

function Session:cancel_build(opts)
  opts = type(opts) == "table" and opts or {}
  if not self:is_active() or not self._state.recursive then
    return false
  end
  local state = self._state
  local record = state.recursive
  record.scheduler:cancel()
  self:_detach_relation_owner(state, record.owner, opts.reason or "recursive build cancelled")
  self:_sync_recursive_status(record)
  if opts.dismiss then
    state.recursive = nil
  else
    record.state = "cancelled"
    record.message = tostring(opts.reason or "cancelled")
  end
  if opts.render ~= false then
    self:_render(state)
  end
  if not opts.silent then
    self._ui.notify("Voyager: recursive build cancelled", vim.log.levels.INFO)
  end
  return true
end

function Session:_invalidate_relation(state, origin_id, method, reason)
  local key = relation_key(origin_id, method)
  local pending = state.relation_requests[key]
  local had_state = pending ~= nil or state.relations[key] ~= nil
  local handles = {}
  state.relation_versions[key] = (state.relation_versions[key] or 0) + 1
  if pending then
    self:_cancel_pending_relation(state, key, pending, reason or "invalidate", true)
  end
  local ordinary = state.ordinary_relation_requests[key]
  if ordinary then
    had_state = true
    state.ordinary_relation_requests[key] = nil
    for request_token in pairs(ordinary) do
      state.invalidated_request_tokens[request_token] = true
      local handle = state.request_handles[request_token]
      if handle then
        table.insert(handles, handle)
      end
      state.request_handles[request_token] = nil
      assert(state.request_count > 0, "Voyager request counter underflow")
      state.request_count = state.request_count - 1
    end
  end
  state.relations[key] = nil
  for _, handle in ipairs(handles) do
    if type(handle) == "table" and type(handle.cancel) == "function" then
      pcall(handle.cancel, handle, reason or "invalidate")
    end
  end
  return had_state
end

function Session:delete_row(row)
  if not self:is_active() then
    return false
  end
  local state = self._state
  if not state.flow then
    return false
  end
  if type(row) ~= "table" or type(row.owner_id) ~= "string" then
    self:_notify_inapplicable("delete", row)
    return false
  end
  if row.kind == "recursive" then
    return self:cancel_build({ dismiss = true, silent = true, reason = "delete" })
  end
  if row.kind == "note" then
    if state.flow:set_note(row.owner_id, nil) then
      self:_render(state)
      return true
    end
    return false
  end
  if row.kind == "relation" then
    local origin_id = self:_row_location_id(row)
    if not origin_id or type(row.method) ~= "string" or row.method == "" then
      self:_notify_inapplicable("delete", row)
      return false
    end
    local key = relation_key(origin_id, row.method)
    if not state.relation_requests[key] and not state.relations[key] then
      return false
    end
    local cancelled_recursive = false
    if state.recursive then
      cancelled_recursive = self:cancel_build({ dismiss = true, silent = true, reason = "delete" })
    end
    if not self:_invalidate_relation(state, origin_id, row.method, "delete") then
      return cancelled_recursive
    end
    self:_render(state)
    return true
  end
  if row.kind == "location" and type(row.action_id) == "string" then
    local action = state.flow:find(row.action_id)
    if not action or action.kind ~= "action" then
      return false
    end
    local linked = false
    for _, target_id in ipairs(state.flow:action_target_ids(action)) do
      linked = linked or target_id == row.owner_id
    end
    if not linked then
      return false
    end
    if state.recursive then
      self:cancel_build({ dismiss = true, silent = true, reason = "delete" })
    end
    if not state.flow:unlink_target(action.id, row.owner_id) then
      return false
    end
    local origin_id = state.flow:parent_id(action.id)
    if origin_id then
      self:_invalidate_relation(state, origin_id, action.method, "delete")
    end
    state.destination_claim = nil
    self:_render(state)
    return true
  end
  if row.kind ~= "location" and row.kind ~= "action" then
    self:_notify_inapplicable("delete", row)
    return false
  end
  if row.owner_id == state.flow.root.id then
    self._ui.notify("Voyager: the flow root cannot be deleted", vim.log.levels.INFO)
    return false
  end
  local target = state.flow:find(row.owner_id)
  if
    not target
    or (row.kind == "location" and target.kind ~= "location")
    or (row.kind == "action" and (target.kind ~= "action" or target.method == "voyager/archive"))
  then
    return false
  end
  local relation_origin_id
  local relation_method
  if row.kind == "action" then
    local action = target
    if action and action.kind == "action" then
      relation_origin_id = state.flow:parent_id(action.id)
      relation_method = action.method
    end
  end
  if state.recursive then
    self:cancel_build({ dismiss = true, silent = true, reason = "delete" })
  end
  local deleted
  if row.kind == "action" and type(state.flow.delete_action_relation) == "function" then
    deleted = state.flow:delete_action_relation(row.owner_id)
  else
    deleted = state.flow:delete(row.owner_id)
  end
  if not deleted then
    return false
  end
  if relation_origin_id and relation_method then
    self:_invalidate_relation(state, relation_origin_id, relation_method, "delete")
  end
  state.destination_claim = nil
  self:_render(state)
  return true
end

function Session:run_action_for_row(row)
  if not self:is_active() then
    return nil
  end
  local state = self._state
  local node_id = self:_row_location_id(row)
  if not node_id then
    self:_notify_inapplicable("run an action", row)
    return nil
  end
  if not self:_jump_to_location(state, node_id, true) then
    return nil
  end
  local token = self:_replace_interaction_token("action_picker")
  local names = Actions.names()
  local opened, select_error = pcall(self._ui.select, names, {
    prompt = "Voyager action",
    format_item = function(name)
      return Actions.get(name).label
    end,
  }, function(choice)
    if not self:_consume_interaction(token) or type(choice) ~= "string" then
      return
    end
    self:run_action(choice)
  end)
  if not opened then
    self:_consume_interaction(token)
    self._ui.notify("Voyager: action picker failed: " .. tostring(select_error), vim.log.levels.ERROR)
    return nil
  end
  return true
end

function Session:_show_location_preview(state, node)
  local lines = state.locator:source(node.location.locator)
  if not lines then
    return state.sidebar:show_preview({
      lines = { "source for " .. tostring(node.location.symbol) .. " is unavailable" },
      title = " " .. tostring(node.location.symbol) .. " ",
      key = node.id .. ":unavailable",
    })
  end
  local start_line = node.location.range.start.line + 1
  local first = math.max(1, start_line - 3)
  local last = math.min(#lines, start_line + 6)
  local slice = {}
  for index = first, last do
    table.insert(slice, lines[index])
  end
  local filetype = ""
  local name = node.location.locator.path or node.location.locator.uri
  if type(name) == "string" then
    filetype = self._runtime.filetype_match(name) or ""
  end
  return state.sidebar:show_preview({
    lines = slice,
    title = " " .. tostring(node.location.symbol) .. " ",
    focus_line = start_line - first + 1,
    filetype = filetype,
    key = node.id,
  })
end

function Session:preview_row(row)
  if not self:is_active() then
    return nil
  end
  local state = self._state
  if type(row) ~= "table" or (row.kind ~= "location" and row.kind ~= "note") then
    self:_notify_inapplicable("preview", row)
    return nil
  end
  local node = state.flow and state.flow:location(row.owner_id) or nil
  if not node then
    self._ui.notify("Voyager: location is no longer available", vim.log.levels.WARN)
    return nil
  end
  local lines = state.locator:source(node.location.locator)
  if not lines then
    self._ui.notify("Voyager: source for " .. tostring(node.location.symbol) .. " is unavailable", vim.log.levels.WARN)
    return nil
  end
  return self:_show_location_preview(state, node)
end

-- Auto-follow: called for every sidebar cursor row; location and note rows
-- open or refresh the preview, everything else hides it.
function Session:follow_preview(row)
  if not self:is_active() then
    return nil
  end
  local state = self._state
  local node
  if type(row) == "table" and (row.kind == "location" or row.kind == "note") and state.flow then
    node = state.flow:location(row.owner_id)
  end
  if not node then
    state.sidebar:close_preview()
    return nil
  end
  return self:_show_location_preview(state, node)
end

function Session:set_all_collapsed(collapsed)
  if not self:is_active() or not self._state.flow then
    return false
  end
  local changed = self._state.flow:set_all_collapsed(collapsed)
  if changed then
    self:_render(self._state)
  end
  return changed
end

function Session:export(row)
  if not self:is_active() or not self._state.flow then
    self._ui.notify("Voyager: no active flow to export", vim.log.levels.INFO)
    return nil
  end
  local state = self._state
  local start_node = state.flow.root
  if row ~= nil then
    if type(row) ~= "table" or type(row.owner_id) ~= "string" then
      self:_notify_inapplicable("export", row)
      return nil
    end
    start_node = row.kind == "note" and state.flow:location(row.owner_id) or state.flow:find(row.owner_id)
    if not start_node then
      self._ui.notify("Voyager: export target is no longer available", vim.log.levels.WARN)
      return nil
    end
  end

  local items = {}
  local skipped = 0
  local function visit(node)
    if node.kind == "location" then
      local target = state.locator:list_target(node.location.locator)
      if target then
        table.insert(
          items,
          vim.tbl_extend("force", target, {
            lnum = node.location.range.start.line + 1,
            col = node.location.range.start.character + 1,
            text = node.location.context or node.location.symbol,
          })
        )
      else
        skipped = skipped + 1
      end
      for _, action in ipairs(node.actions) do
        visit(action)
      end
    else
      for _, result in ipairs(node.results) do
        visit(result)
      end
    end
  end
  visit(start_node)

  if #items == 0 then
    self._ui.notify("Voyager: nothing exportable in this flow", vim.log.levels.INFO)
    return nil
  end
  self._runtime.set_quickfix({ title = "Voyager: " .. state.flow.name, items = items })
  local message = string.format("Voyager: exported %d location%s to quickfix", #items, #items == 1 and "" or "s")
  if skipped > 0 then
    message = message .. string.format(" (%d unresolvable skipped)", skipped)
  end
  self._ui.notify(message, vim.log.levels.INFO)
  return #items
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
  local node = state.flow and state.flow:location(node_id) or nil
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

function Session:_resolve_dirty(intent, continuation)
  local state = self._state
  if state and state.config.storage.autosave == true and self:save(continuation) then
    return true
  end
  return self:_decide_dirty(intent, continuation)
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
  self._interaction_tokens.action_picker = nil
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
  if not state.flow then
    self._ui.notify("Voyager: nothing recorded yet", vim.log.levels.INFO)
    return nil
  end
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

  self:_guard_recursive_relations(state)
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
    if old.recursive then
      self:cancel_build({ dismiss = true, silent = true, render = false, reason = "load" })
    end
    old.phase = "replacing"
    old.generation = staged.generation
    self:_invalidate_interactions(old)
    for _, handle in pairs(old.request_handles) do
      pcall(handle.cancel, handle, "load")
    end
    old.request_handles = {}
    old.relation_requests = {}
    old.ordinary_relation_requests = {}
    old.relation_versions = {}
    old.directional_request_tokens = {}
    old.invalidated_request_tokens = {}
    old.relations = {}
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
    if self:is_active() and self._state.flow ~= nil and self._state.flow:is_dirty() then
      self:_resolve_dirty("load", load_and_install)
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
  if state.recursive then
    self:cancel_build({ dismiss = true, silent = true, render = false, reason = source or "close" })
  end
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
  state.relation_requests = {}
  state.ordinary_relation_requests = {}
  state.relation_versions = {}
  state.directional_request_tokens = {}
  state.invalidated_request_tokens = {}
  state.relations = {}
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
  if state.flow ~= nil and state.flow:is_dirty() then
    return self:_resolve_dirty("close", function()
      self:_teardown(source)
    end)
  end
  return self:_teardown(source)
end

function Session:shutdown()
  local state = self._state
  if self:is_active() and state.recursive then
    self:cancel_build({ dismiss = true, silent = true, reason = "shutdown" })
  end
  if
    self:is_active()
    and state.phase == "active"
    and state.config.storage.autosave == true
    and state.flow ~= nil
    and state.flow:is_dirty()
  then
    pcall(self.save, self)
  end
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
  local Symbols = require("voyager.symbols")

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
    symbols = function(locator)
      return Symbols.new({
        locator = locator,
        get_clients = runtime.get_clients,
        request_group = recording_request_group,
        timer = runtime.timer,
        filetype_match = runtime.filetype_match,
        get_string_parser = runtime.ts_string_parser,
        get_node_text = runtime.ts_node_text,
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
          activate_stay = function(row)
            return controller:activate_row(row, { stay = true })
          end,
          run_action = function(row)
            return controller:run_action_for_row(row)
          end,
          show_callers = function(row)
            return controller:show_callers(row, false)
          end,
          show_callees = function(row)
            return controller:show_callees(row, false)
          end,
          refresh_callers = function(row)
            return controller:show_callers(row, true)
          end,
          refresh_callees = function(row)
            return controller:show_callees(row, true)
          end,
          build_callers = function(row)
            return controller:start_recursive(row, "callers")
          end,
          build_callees = function(row)
            return controller:start_recursive(row, "callees")
          end,
          cancel_build = function()
            return controller:cancel_build()
          end,
          delete = function(row)
            return controller:delete_row(row)
          end,
          preview = function(row)
            return controller:preview_row(row)
          end,
          cursor_row = function(row)
            return controller:follow_preview(row)
          end,
          collapse_all = function()
            return controller:set_all_collapsed(true)
          end,
          expand_all = function()
            return controller:set_all_collapsed(false)
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
    symbols_factory = factories.symbols,
    ui = { input = runtime.input, select = runtime.select, notify = runtime.notify },
  })
  return controller
end

return M
