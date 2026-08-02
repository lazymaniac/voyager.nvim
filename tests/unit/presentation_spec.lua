local Actions = require("voyager.lsp.actions")
local Presentation = require("voyager.lsp.presentation")

local created_buffers
local created_windows

local function buffer(lines)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  table.insert(created_buffers, bufnr)
  return bufnr
end

local function fixture()
  local source = buffer({ "source", "live cursor moved" })
  local target = buffer({ "a😀b" })
  local source_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(source_win, source)
  local location = {
    locator = { kind = "project", path = "lua/auth.lua" },
    range = { start = { line = 0, character = 1 }, ["end"] = { line = 0, character = 5 } },
    symbol = "auth.lua:1",
    identity = '["project","lua/auth.lua",0,1,0,5]',
  }
  local raw = {
    targetUri = "file:///project/lua/auth.lua",
    targetSelectionRange = {
      start = { line = 0, character = 1 },
      ["end"] = { line = 0, character = 3 },
    },
  }
  local item = {
    identity = location.identity,
    node_id = "loc-result",
    location = location,
    raw = raw,
    list_item = { bufnr = target, lnum = 1, col = 2, end_lnum = 1, end_col = 6, text = "a😀b" },
  }
  return {
    source = source,
    source_win = source_win,
    target = target,
    location = location,
    raw = raw,
    item = item,
    context = {
      generation = 4,
      request_token = 12,
      bufnr = source,
      winid = source_win,
      from = { source, 3, 7, 0 },
      tagname = "authorize",
      project_root = "/project",
    },
  }
end

local function close_list_windows()
  pcall(vim.cmd, "silent! cclose")
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_win_call, winid, function() vim.cmd("silent! lclose") end)
    end
  end
end

local function presenter(env, navigation, overrides)
  overrides = overrides or {}
  local current = {}
  local nodes = { [env.item.node_id] = env.location }
  local instance = Presentation.new({
    navigation = vim.tbl_extend("force", {
      loclist = false,
      reuse_win = false,
      on_list = nil,
    }, navigation or {}),
    resolve_node = function(node_id)
      if overrides.resolve_node then
        return overrides.resolve_node(node_id)
      end
      return nodes[node_id]
    end,
    choose_window = overrides.choose_window or function() return env.source_win end,
    set_current = function(node_id) table.insert(current, node_id) end,
    notify = function(message) overrides.notification = message end,
  })
  return instance, current, overrides
end

local function tagged_item(env, marker)
  local value = vim.deepcopy(env.item)
  value.raw.marker = marker
  return value
end

describe("Voyager LSP presentation", function()
  before_each(function()
    close_list_windows()
    vim.fn.setqflist({}, "r")
    created_buffers = {}
    created_windows = {}
  end)

  after_each(function()
    close_list_windows()
    for index = #created_windows, 1, -1 do
      local winid = created_windows[index]
      if vim.api.nvim_win_is_valid(winid) and #vim.api.nvim_list_wins() > 1 then
        vim.api.nvim_win_close(winid, true)
      end
    end
    for _, bufnr in ipairs(created_buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
    vim.fn.setqflist({}, "r")
  end)

  it("jumps once with invocation-time jumplist and tagstack data", function()
    local env = fixture()
    local instance, current = presenter(env)
    vim.fn.settagstack(env.source_win, { items = {} }, "r")
    vim.api.nvim_win_set_cursor(env.source_win, { 2, 3 })
    vim.bo[env.target].buflisted = false

    instance:present(env.context, { env.item }, Actions.get("definition"))

    assert.equals(env.target, vim.api.nvim_win_get_buf(env.source_win))
    assert.same({ 1, 1 }, vim.api.nvim_win_get_cursor(env.source_win))
    assert.is_true(vim.bo[env.target].buflisted)
    assert.same({ "loc-result" }, current)
    local tags = vim.fn.gettagstack(env.source_win).items
    assert.same({ tagname = "authorize", from = env.context.from }, {
      tagname = tags[#tags].tagname,
      from = tags[#tags].from,
    })
    local jumps = vim.fn.getjumplist(env.source_win)[1]
    assert.is_true(vim.iter(jumps):any(function(jump)
      return jump.bufnr == env.source and jump.lnum == 2 and jump.col == 3
    end))
    assert.equals(-1, vim.api.nvim_win_call(env.source_win, function() return vim.fn.foldclosed(1) end))
  end)

  it("does nothing when no eligible jump window exists", function()
    local env = fixture()
    local instance, current = presenter(env, nil, { choose_window = function() return nil end })
    vim.fn.settagstack(env.source_win, { items = {} }, "r")
    local jumps_before = vim.deepcopy(vim.fn.getjumplist(env.source_win))

    instance:present(env.context, { env.item }, Actions.get("definition"))

    assert.equals(env.source, vim.api.nvim_win_get_buf(env.source_win))
    assert.same({}, vim.fn.gettagstack(env.source_win).items)
    assert.same(jumps_before, vim.fn.getjumplist(env.source_win))
    assert.same({}, current)
  end)

  it("reuses an already-visible target window when configured", function()
    local env = fixture()
    vim.api.nvim_set_current_win(env.source_win)
    vim.cmd("vsplit")
    local target_win = vim.api.nvim_get_current_win()
    table.insert(created_windows, target_win)
    vim.api.nvim_win_set_buf(target_win, env.target)
    vim.api.nvim_set_current_win(env.source_win)
    local instance, current = presenter(env, { reuse_win = true })

    instance:present(env.context, { env.item }, Actions.get("definition"))

    assert.equals(target_win, vim.api.nvim_get_current_win())
    assert.equals(env.target, vim.api.nvim_win_get_buf(target_win))
    assert.same({ 1, 1 }, vim.api.nvim_win_get_cursor(target_win))
    assert.same({ "loc-result" }, current)
  end)

  it("opens raw duplicate quickfix items and selects only the tagged active tuple", function()
    local env = fixture()
    local instance, current = presenter(env)
    local first = tagged_item(env, "first")
    local second = tagged_item(env, "second")

    instance:present(env.context, { first, second }, Actions.get("implementation"))

    local list = vim.fn.getqflist({ id = 0, idx = 0, title = 0, context = 0, items = 0 })
    assert.equals(2, #list.items)
    assert.equals("implementations", list.title)
    assert.same({ bufnr = env.source, method = "textDocument/implementation" }, list.context)
    assert.equals("first", list.items[1].user_data.marker)
    assert.equals("second", list.items[2].user_data.marker)
    assert.same({ generation = 4, request_token = 12, node_id = "loc-result" }, list.items[1].user_data.voyager)
    assert.is_nil(first.raw.voyager)

    vim.cmd("cfirst")
    local target_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(target_win, { 1, 0 })
    instance:on_cursor_moved(target_win)
    assert.same({}, current)
    vim.api.nvim_win_set_cursor(target_win, { 1, 1 })
    instance:on_cursor_moved(target_win)
    instance:on_cursor_moved(target_win)
    assert.same({ "loc-result" }, current)
  end)

  it("uses a location-list owner fallback and preserves call objects", function()
    local env = fixture()
    local call = {
      from = { name = "caller", uri = "file:///project/caller.lua" },
      fromRanges = { env.raw.targetSelectionRange },
    }
    local item = vim.deepcopy(env.item)
    item.raw = call
    env.context.winid = 999999
    local instance = presenter(env, { loclist = true })

    instance:present(env.context, { item }, Actions.get("incoming_calls"))

    local list = vim.fn.getloclist(env.source_win, { id = 0, idx = 0, title = 0, context = 0, items = 0 })
    assert.equals(1, #list.items)
    assert.equals("incoming calls", list.title)
    assert.same({ bufnr = env.source, method = "callHierarchy/incomingCalls" }, list.context)
    assert.equals("caller", list.items[1].user_data.from.name)
    assert.same({ generation = 4, request_token = 12, node_id = "loc-result" }, list.items[1].user_data.voyager)
    assert.is_nil(call.voyager)
  end)

  it("rejects a replaced quickfix list even at the same target coordinate", function()
    local env = fixture()
    local instance, current = presenter(env)
    instance:present(env.context, { env.item }, Actions.get("references"))
    local original = vim.fn.getqflist({ id = 0, items = 0 })
    vim.fn.setqflist({}, " ", { title = "replacement", items = original.items })

    vim.api.nvim_win_set_buf(env.source_win, env.target)
    vim.api.nvim_win_set_cursor(env.source_win, { 1, 1 })
    instance:on_cursor_moved(env.source_win)
    assert.same({}, current)
  end)

  it("lets custom on_list own every non-empty presentation and invalidates old selectors", function()
    local env = fixture()
    local calls = {}
    local captures = {}
    local instance = Presentation.new({
      navigation = {
        loclist = false,
        reuse_win = false,
        on_list = function(list, select)
          table.insert(captures, { list = list, select = select })
        end,
      },
      resolve_node = function(node_id) return node_id == "loc-result" and env.location or nil end,
      choose_window = function() return env.source_win end,
      set_current = function(node_id) table.insert(calls, node_id) end,
      notify = function() end,
    })

    instance:present(env.context, { env.item }, Actions.get("definition"))
    assert.equals(1, #captures)
    assert.equals("definition", captures[1].list.title)
    assert.same({ bufnr = env.source, method = "textDocument/definition" }, captures[1].list.context)
    assert.same({}, calls)
    assert.equals(env.source, vim.api.nvim_win_get_buf(env.source_win))

    local untagged = vim.deepcopy(captures[1].list.items[1])
    untagged.user_data.voyager = nil
    captures[1].select(untagged)
    assert.same({}, calls)

    captures[1].select(captures[1].list.items[1])
    assert.same({ "loc-result" }, calls)
    assert.equals(env.target, vim.api.nvim_win_get_buf(env.source_win))

    vim.api.nvim_win_set_buf(env.source_win, env.source)
    instance:present(env.context, { env.item }, Actions.get("definition"))
    captures[1].select(captures[1].list.items[1])
    assert.equals(env.source, vim.api.nvim_win_get_buf(env.source_win))
    assert.same({ "loc-result" }, calls)

    instance:invalidate()
    captures[2].select(captures[2].list.items[1])
    assert.same({ "loc-result" }, calls)
  end)
end)
