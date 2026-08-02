local Config = require("voyager.config")
local Flow = require("voyager.flow")

local M = {}

local function fake_sidebar(env)
  local sidebar = {
    winid = 9001,
    bufnr = 9002,
    focus_count = 0,
    mount_calls = {},
    remount_calls = {},
    render_calls = {},
    render_count = 0,
    unmount_calls = {},
    mounted = false,
    mount_result = true,
    remount_result = true,
  }

  local function show()
    sidebar.mounted = true
    env.buffers[sidebar.bufnr] = {
      name = "",
      buftype = "nofile",
      buflisted = false,
      loaded = true,
      valid = true,
      lines = {},
    }
    env.windows[sidebar.winid] = {
      bufnr = sidebar.bufnr,
      tabpage = env.current_tabpage_id,
      relative = "editor",
      valid = true,
    }
  end

  local function hide()
    sidebar.mounted = false
    env.windows[sidebar.winid] = nil
  end

  function sidebar:mount(opts)
    table.insert(self.mount_calls, vim.deepcopy(opts))
    if self.on_mount then
      self.on_mount(opts)
    end
    if not self.mount_result then
      hide()
      return nil, self.mount_error or "mount failed"
    end
    show()
    if opts.focus then
      self:focus()
    end
    return true
  end

  function sidebar:remount(opts)
    table.insert(self.remount_calls, vim.deepcopy(opts))
    if not self.remount_result then
      hide()
      return nil, self.remount_error or "remount failed"
    end
    show()
    if opts.focus then
      self:focus()
    end
    return true
  end

  function sidebar:unmount(opts)
    table.insert(self.unmount_calls, vim.deepcopy(opts))
    hide()
  end

  function sidebar:render(flow, status)
    self.render_count = self.render_count + 1
    table.insert(self.render_calls, { flow = flow, status = vim.deepcopy(status) })
  end

  function sidebar:focus()
    if not self.mounted then
      return false
    end
    self.focus_count = self.focus_count + 1
    env.current_win_id = self.winid
    return true
  end

  function sidebar:is_mounted()
    return self.mounted
  end

  function sidebar:owns_window(winid)
    return self.mounted and winid == self.winid
  end

  return sidebar
end

local function fake_keymaps()
  local keymaps = {
    applied_buffers = {},
    apply_calls = {},
    restored_generations = {},
  }
  function keymaps:apply_buffer(bufnr, generation, mappings, wrapper_factory)
    table.insert(self.applied_buffers, bufnr)
    table.insert(self.apply_calls, {
      bufnr = bufnr,
      generation = generation,
      mappings = vim.deepcopy(mappings),
      wrapper_factory = wrapper_factory,
    })
  end
  function keymaps:restore_all(generation)
    table.insert(self.restored_generations, generation)
  end
  return keymaps
end

local function fake_presenter()
  local presenter = { invalidate_calls = 0, cursor_calls = {}, present_calls = {} }
  function presenter:invalidate()
    self.invalidate_calls = self.invalidate_calls + 1
  end
  function presenter:on_cursor_moved(winid)
    table.insert(self.cursor_calls, winid)
  end
  function presenter:present(context, items, action)
    table.insert(self.present_calls, {
      context = vim.deepcopy(context),
      items = vim.deepcopy(items),
      action = vim.deepcopy(action),
    })
    if self.on_present then
      self.on_present(context, items, action)
    end
  end
  return presenter
end

local function fake_lsp()
  local lsp = { starts = {}, handles = {} }
  function lsp:start(action_name, context, callback)
    if self.start_error then
      error(self.start_error)
    end
    local handle = { cancel_calls = {}, supersede_calls = 0, done = false }
    function handle:cancel(reason)
      table.insert(self.cancel_calls, reason)
    end
    function handle:supersede_interactive()
      self.supersede_calls = self.supersede_calls + 1
      if self.on_supersede then
        self.on_supersede()
      end
    end
    function handle:is_done()
      return self.done
    end
    table.insert(self.starts, {
      action_name = action_name,
      context = vim.deepcopy(context),
      callback = callback,
      handle = handle,
    })
    table.insert(self.handles, handle)
    if self.auto_outcome then
      handle.done = true
      callback(vim.deepcopy(self.auto_outcome))
      if self.complete_twice then
        callback(vim.deepcopy(self.auto_outcome))
      end
    end
    return handle
  end
  function lsp:complete(index, outcome)
    local start = assert(self.starts[index])
    start.handle.done = true
    start.callback(vim.deepcopy(outcome))
  end
  return lsp
end

function M.new(overrides)
  overrides = overrides or {}
  local env = {
    origin_buf = 11,
    origin_win = 21,
    origin_tab = 31,
    project_root = "/project",
    current_win_id = 21,
    current_tabpage_id = 31,
    notifications = {},
    autocmds = {},
    autocmd_calls = {},
    deleted_augroups = {},
    next_augroup = 100,
    clients = { { id = 7, name = "fake", config = { root_dir = "/project" } } },
    buffers = {},
    windows = {},
    locator_factory_calls = {},
    store_factory_calls = {},
    lsp_factory_calls = {},
    presenter_factory_calls = {},
    sidebar_factory_calls = {},
    keymaps_factory_calls = 0,
    cursor_word = "main",
    cursor_word_start = 6,
    cursor_word_end = 10,
    fold_open_calls = {},
  }
  env.buffers[env.origin_buf] = {
    name = overrides.buffer_name or "/project/lua/main.lua",
    buftype = overrides.buftype or "",
    buflisted = true,
    loaded = true,
    valid = true,
    lines = { "local main = true" },
  }
  env.windows[env.origin_win] = {
    bufnr = env.origin_buf,
    tabpage = env.origin_tab,
    relative = "",
    valid = true,
    cursor = { 1, 6 },
  }

  env.runtime = {
    now = function()
      return "2026-08-02T10:00:00Z"
    end,
    random = function(length)
      if env.random_error then
        return nil, env.random_error
      end
      return string.rep("\1", length)
    end,
    sha256 = vim.fn.sha256,
    cwd = function()
      return "/project"
    end,
    dirname = vim.fs.dirname,
    fs_realpath = function(path)
      return vim.fs.normalize(path, { expand_env = false })
    end,
    find_root = function()
      return "/project"
    end,
    current_buf = function()
      local win = env.windows[env.current_win_id]
      return win and win.bufnr or env.origin_buf
    end,
    current_win = function()
      return env.current_win_id
    end,
    current_tabpage = function()
      return env.current_tabpage_id
    end,
    list_wins = function()
      local result = {}
      for winid, window in pairs(env.windows) do
        if window.valid ~= false then
          table.insert(result, winid)
        end
      end
      table.sort(result)
      return result
    end,
    win_valid = function(winid)
      return env.windows[winid] ~= nil and env.windows[winid].valid ~= false
    end,
    win_buf = function(winid)
      return assert(env.windows[winid]).bufnr
    end,
    win_tab = function(winid)
      return assert(env.windows[winid]).tabpage
    end,
    win_config = function(winid)
      return { relative = assert(env.windows[winid]).relative }
    end,
    set_current_win = function(winid)
      assert(env.windows[winid] and env.windows[winid].valid ~= false)
      env.current_win_id = winid
      env.current_tabpage_id = env.windows[winid].tabpage
    end,
    set_win_buf = function(winid, bufnr)
      assert(env.windows[winid] and env.buffers[bufnr])
      env.windows[winid].bufnr = bufnr
    end,
    set_win_cursor = function(winid, cursor)
      assert(env.windows[winid])
      env.windows[winid].cursor = vim.deepcopy(cursor)
    end,
    open_folds = function(winid)
      table.insert(env.fold_open_calls, winid)
    end,
    buffer_valid = function(bufnr)
      return env.buffers[bufnr] ~= nil and env.buffers[bufnr].valid ~= false
    end,
    buffer_loaded = function(bufnr)
      return env.buffers[bufnr] ~= nil and env.buffers[bufnr].loaded == true
    end,
    buffer_name = function(bufnr)
      return assert(env.buffers[bufnr]).name
    end,
    buffer_option = function(bufnr, name)
      return assert(env.buffers[bufnr])[name]
    end,
    get_buffer_lines = function(bufnr)
      return vim.deepcopy(assert(env.buffers[bufnr]).lines)
    end,
    cursor = function(winid)
      local cursor = assert(env.windows[winid]).cursor or { 1, 0 }
      return { line = cursor[1] - 1, character = cursor[2] }
    end,
    getpos = function(winid)
      local cursor = assert(env.windows[winid]).cursor or { 1, 0 }
      return { 0, cursor[1], cursor[2] + 1, 0 }
    end,
    word_at_cursor = function()
      return env.cursor_word, env.cursor_word_start, env.cursor_word_end
    end,
    get_clients = function(filter)
      env.last_client_filter = vim.deepcopy(filter)
      return env.clients
    end,
    create_augroup = function(name, opts)
      env.next_augroup = env.next_augroup + 1
      env.created_augroup = { id = env.next_augroup, name = name, opts = vim.deepcopy(opts) }
      return env.next_augroup
    end,
    delete_augroup = function(id)
      table.insert(env.deleted_augroups, id)
    end,
    create_autocmd = function(event, opts)
      table.insert(env.autocmd_calls, { event = event, opts = opts })
      env.autocmds[event] = opts.callback
      return #env.autocmd_calls
    end,
    notify = function(message, level)
      table.insert(env.notifications, { message = message, level = level })
    end,
    input = function(opts, callback)
      env.input_opts = vim.deepcopy(opts)
      env.input_callback = callback
    end,
    select = function(items, opts, callback)
      if env.select_error then
        error(env.select_error)
      end
      env.select_items = vim.deepcopy(items)
      env.select_opts = opts
      env.select_callback = callback
    end,
  }

  function env:add_window(winid, bufnr, tabpage)
    self.windows[winid] = {
      bufnr = bufnr,
      tabpage = tabpage or self.current_tabpage_id,
      relative = "",
      valid = true,
      cursor = { 1, 0 },
    }
  end

  function env:add_buffer(bufnr, name, opts)
    opts = opts or {}
    self.buffers[bufnr] = {
      name = name,
      buftype = opts.buftype or "",
      buflisted = opts.buflisted ~= false,
      loaded = opts.loaded ~= false,
      valid = opts.valid ~= false,
      lines = opts.lines or { "content" },
    }
  end

  function env:set_cursor(byte_col, word, start_col, end_col)
    env.windows[env.current_win_id].cursor = { 1, byte_col }
    env.cursor_word = word
    env.cursor_word_start = start_col
    env.cursor_word_end = end_col
  end

  function env:trigger(event, args)
    assert(self.autocmds[event], "autocmd not registered: " .. event)(args or {})
  end

  env.config = Config.resolve()
  env.sidebar = fake_sidebar(env)
  env.keymaps = fake_keymaps()
  env.presenter = fake_presenter()
  env.lsp = fake_lsp()
  env.locator = {
    _project_root = env.project_root,
    stale = false,
    open_target_calls = {},
  }
  function env.locator:is_stale()
    return self.stale, self.stale and (self.stale_reason or "location is stale") or nil
  end
  function env.locator:open_target(location)
    table.insert(self.open_target_calls, vim.deepcopy(location))
    local stale, reason = self:is_stale(location)
    if stale then
      return nil, reason
    end
    if self.open_target_error then
      return nil, self.open_target_error
    end
    if self.open_target_result then
      return vim.deepcopy(self.open_target_result)
    end
    return {
      bufnr = env.origin_buf,
      row = location.range.start.line + 1,
      col = location.range.start.character,
    }
  end

  env.store = {
    project_root_calls = {},
    save_calls = {},
    list_calls = {},
    load_calls = {},
    entries = {},
    warnings = {},
  }
  function env.store:project_root(bufnr, clients, cwd)
    table.insert(self.project_root_calls, { bufnr = bufnr, clients = clients, cwd = cwd })
    return env.project_root
  end
  function env.store:save(flow)
    table.insert(self.save_calls, flow)
    if self.save_error then
      return nil, self.save_error
    end
    local document = {}
    for _, key in ipairs({
      "schema_version",
      "position_encoding",
      "revision",
      "flow_id",
      "name",
      "root_key",
      "created_at",
      "updated_at",
      "current_node_id",
      "root",
    }) do
      document[key] = vim.deepcopy(flow[key])
    end
    document.revision = document.revision + 1
    flow:mark_saved(document)
    return document
  end
  function env.store:list(project_root)
    table.insert(self.list_calls, project_root)
    if self.list_error then
      error(self.list_error)
    end
    return vim.deepcopy(self.entries), vim.deepcopy(self.warnings)
  end
  function env.store:load(entry, project_root)
    table.insert(self.load_calls, { vim.deepcopy(entry), project_root })
    if self.load_error then
      return nil, self.load_error
    end
    if self.load_hook then
      return self.load_hook(entry, project_root)
    end
    return self.load_result
  end

  local flow_module = {}
  setmetatable(flow_module, { __index = Flow })
  function flow_module.new(opts)
    local flow = Flow.new(opts)
    env.flow = flow
    env.root_id = flow.root.id
    return flow
  end
  env.flow_module = flow_module

  function env:new_sidebar()
    return fake_sidebar(self)
  end
  function env:new_keymaps()
    return fake_keymaps()
  end
  function env:new_presenter()
    return fake_presenter()
  end
  function env:new_lsp()
    return fake_lsp()
  end

  function env:session_options()
    return {
      config_provider = function()
        return vim.deepcopy(env.config)
      end,
      runtime = env.runtime,
      flow = env.flow_module,
      locator_factory = function(project_root, resolve_uri)
        table.insert(env.locator_factory_calls, { project_root = project_root, resolve_uri = resolve_uri })
        env.locator._project_root = project_root
        return env.locator
      end,
      store_factory = function(locator)
        table.insert(env.store_factory_calls, locator)
        return env.store
      end,
      keymaps_factory = function()
        env.keymaps_factory_calls = env.keymaps_factory_calls + 1
        local value = env.next_keymaps or env.keymaps
        env.next_keymaps = nil
        return value
      end,
      sidebar_factory = function(config)
        table.insert(env.sidebar_factory_calls, vim.deepcopy(config))
        local value = env.next_sidebar or env.sidebar
        env.next_sidebar = nil
        return value
      end,
      lsp_factory = function(locator, config)
        table.insert(env.lsp_factory_calls, { locator = locator, config = vim.deepcopy(config) })
        local value = env.next_lsp or env.lsp
        env.next_lsp = nil
        return value
      end,
      presenter_factory = function(config)
        table.insert(env.presenter_factory_calls, vim.deepcopy(config))
        local value = env.next_presenter or env.presenter
        env.next_presenter = nil
        return value
      end,
      ui = { input = env.runtime.input, select = env.runtime.select, notify = env.runtime.notify },
    }
  end

  return env
end

return M
