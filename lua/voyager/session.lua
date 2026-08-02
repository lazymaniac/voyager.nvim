local Locator = require("voyager.locator")

local M = {}
local Session = {}
Session.__index = Session

local active_phases = {
  active = true,
  deciding = true,
  saving = true,
}

local function normalize(path)
  local value = path:gsub("\\", "/")
  return vim.fs.normalize(value)
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
  table.sort(roots, function(left, right) return #left > #right end)
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
    _keymaps_factory = opts.keymaps_factory,
    _sidebar_factory = opts.sidebar_factory,
    _lsp_factory = opts.lsp_factory,
    _presenter_factory = opts.presenter_factory,
    _ui = opts.ui,
    _generation = 0,
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
      if locator.kind == "project"
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
    presentation_token = 0,
    current_claim_token = 0,
    manual_claim_token = 0,
    source_windows = vim.deepcopy(opts.source_windows or { opts.origin_win }),
    origin_buf = opts.origin_buf,
    origin_win = opts.origin_win,
    tabpage = opts.tabpage,
    locator = locator,
    store = store,
  }
  state.keymaps = self._keymaps_factory()
  state.sidebar = self._sidebar_factory(config)
  state.lsp = self._lsp_factory(locator, config)
  state.presenter = self._presenter_factory(config)
  return state
end

function Session:_render(state)
  state.sidebar:render(state.flow, {
    dirty = state.flow:is_dirty(),
    request_count = state.request_count,
  })
end

function Session:_apply_source_mappings(state, bufnr)
  bufnr = bufnr or state.origin_buf
  if not self:_eligible_buffer(state, bufnr) then
    return
  end
  state.keymaps:apply_buffer(bufnr, state.generation, state.config.lsp_keymaps, function(action_name)
    return function()
      self:run_action(action_name)
    end
  end)
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

  for _, event in ipairs({ "BufEnter", "LspAttach" }) do
    runtime.create_autocmd(event, {
      group = state.autocmd_group,
      callback = guarded(function(args)
        local bufnr = args.buf or runtime.current_buf()
        self:_apply_source_mappings(state, bufnr)
      end),
    })
  end
  runtime.create_autocmd("WinEnter", {
    group = state.autocmd_group,
    callback = guarded(function()
      local winid = runtime.current_win()
      self:_record_source_window(state, winid)
      state.presenter:on_cursor_moved(winid)
    end),
  })
  runtime.create_autocmd("WinClosed", {
    group = state.autocmd_group,
    callback = guarded(function(args)
      local closed = tonumber(args.match)
      if closed then
        state.source_windows = vim.tbl_filter(function(winid) return winid ~= closed end, state.source_windows)
      end
    end),
  })
  runtime.create_autocmd("TabEnter", {
    group = state.autocmd_group,
    callback = guarded(function() self:_remount_for_event(state) end),
  })
  runtime.create_autocmd("VimResized", {
    group = state.autocmd_group,
    callback = guarded(function() self:_remount_for_event(state) end),
  })
  runtime.create_autocmd("VimLeavePre", {
    group = state.autocmd_group,
    callback = guarded(function() self:shutdown() end),
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
    self._ui.notify("Voyager: could not create flow: " .. tostring(nonce_error or "entropy unavailable"), vim.log.levels.ERROR)
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
  self:_apply_source_mappings(staged)
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

function Session:_invalidate_interactions(state)
  state.interaction_token = state.interaction_token + 1
  state.interaction_tokens = {}
  state.presentation_token = state.presentation_token + 1
  state.current_claim_token = state.current_claim_token + 1
  state.manual_claim_token = state.manual_claim_token + 1
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
  state.presenter:invalidate()
  self:_delete_autocmds(state)
  state.sidebar:unmount({ owned = true })
  state.keymaps:restore_all(previous_generation)
  if owned_focus and fallback and self._runtime.win_valid(fallback) then
    self._runtime.set_current_win(fallback)
  end
  state.phase = "closed"
  return true
end

function Session:close(source)
  return self:_teardown(source or "close")
end

function Session:shutdown()
  return self:_teardown("shutdown")
end

function Session:_resolve_location(node_id)
  if not self:is_active() then
    return nil
  end
  return self._state.flow:location(node_id)
end

function M.native(config_provider, runtime, overrides)
  local Store = require("voyager.store")
  local Schema = require("voyager.schema")
  local Flow = require("voyager.flow")
  local Keymaps = require("voyager.keymaps")
  local Sidebar = require("voyager.sidebar")
  local Actions = require("voyager.lsp.actions")
  local Normalize = require("voyager.lsp.normalize")
  local RequestGroup = require("voyager.lsp.request_group")
  local Lsp = require("voyager.lsp")
  local Presentation = require("voyager.lsp.presentation")

  local factories = vim.tbl_extend("force", {
    flow = Flow,
    locator = function(root_dir, resolve_uri)
      return Locator.new(runtime, root_dir, resolve_uri)
    end,
    store = function(locator)
      return Store.new({ runtime = runtime, schema = Schema, locator = locator, flow = Flow })
    end,
    keymaps = function()
      return Keymaps.new({ notify = runtime.notify })
    end,
    sidebar = function(opts)
      return Sidebar.new(opts)
    end,
    lsp = function(locator, config)
      return Lsp.new({
        actions = Actions,
        normalizer = Normalize.new({ locator = locator }),
        request_group = RequestGroup,
        get_clients = runtime.get_clients,
        make_position_params = runtime.make_position_params,
        timer = runtime.timer,
        select = runtime.select,
      })
    end,
    presenter = function(opts)
      return Presentation.new(opts)
    end,
  }, overrides or {})

  local controller
  controller = M.new({
    config_provider = config_provider,
    runtime = runtime,
    flow = factories.flow,
    locator_factory = factories.locator,
    store_factory = factories.store,
    keymaps_factory = factories.keymaps,
    sidebar_factory = function(config)
      return factories.sidebar({
        sidebar = config.sidebar,
        keymaps = config.sidebar_keymaps,
        handlers = {
          activate = function(row) return controller:activate_row(row) end,
          note = function(row) return controller:edit_note(row) end,
          save = function() return controller:save() end,
          load = function() return controller:load() end,
          toggle = function(row) return controller:toggle_row(row) end,
          close = function() return controller:close("sidebar") end,
          external_close = function() return controller:close("external_popup") end,
        },
        notify = runtime.notify,
      })
    end,
    lsp_factory = factories.lsp,
    presenter_factory = function(config)
      return factories.presenter({
        navigation = config.navigation,
        resolve_node = function(node_id) return controller:_resolve_location(node_id) end,
        choose_window = function() return controller:choose_jump_window() end,
        set_current = function(node_id) return controller:set_current(node_id) end,
        notify = runtime.notify,
      })
    end,
    ui = { input = runtime.input, select = runtime.select, notify = runtime.notify },
  })
  return controller
end

return M
