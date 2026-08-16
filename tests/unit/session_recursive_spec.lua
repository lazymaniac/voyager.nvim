local Actions = require("voyager.lsp.actions")
local FakeSessionDeps = require("tests.helpers.fake_session_deps")
local Fixtures = require("tests.helpers.flow")
local Locator = require("voyager.locator")
local Session = require("voyager.session")

local function new_session(opts)
  opts = opts or {}
  local deps = FakeSessionDeps.new()
  if opts.recursive then
    deps.config.navigation.recursive = vim.tbl_extend("force", deps.config.navigation.recursive, opts.recursive)
  end
  if opts.defer_symbols ~= true then
    deps.symbols.auto_results = {}
  end
  local session = Session.new(deps:session_options())
  assert.is_true(session:open())
  if opts.ensure ~= false then
    assert.is_true(session:ensure_flow())
  end
  return session, deps
end

local function row(node_id)
  return { kind = "location", owner_id = node_id, context_location_id = node_id }
end

local function outcome(action_name, origin_id, locations, opts)
  opts = opts or {}
  local action = Actions.get(action_name)
  local items = {}
  for _, location in ipairs(locations or {}) do
    table.insert(items, {
      identity = location.identity or Locator.location_key(location),
      location = vim.deepcopy(location),
      raw = {},
    })
  end
  return {
    status = opts.status or (#items > 0 and "success" or "empty"),
    action = action,
    method = action.method,
    label = action.label,
    origin_node_id = origin_id,
    items = items,
    locations = vim.deepcopy(locations or {}),
    failures = vim.deepcopy(opts.failures or {}),
  }
end

local function complete(deps, index, locations, opts)
  local start = assert(deps.lsp.starts[index])
  deps.lsp:complete(index, outcome(start.action_name, start.context.origin_node_id, locations, opts))
end

local function last_notification(deps)
  return deps.notifications[#deps.notifications] and deps.notifications[#deps.notifications].message or nil
end

describe("Voyager recursive session integration", function()
  it("captures an initial cursor root and resolves configured and explicit directions", function()
    local session, deps = new_session({ ensure = false })
    local original_window = deps.current_win_id

    local scheduler = session:build({ direction = "callers", depth = 1 })

    assert.is_table(scheduler)
    local state = session:state()
    assert.is_table(state.flow)
    assert.equals(state.flow.root.id, state.recursive.seed_id)
    assert.equals("callers", state.recursive.direction)
    assert.equals(Actions.get("incoming_calls").method, state.recursive.method)
    assert.equals(original_window, deps.current_win_id)
    assert.equals(0, #deps.sidebar.focus_recursive_calls)

    deps:flush_scheduled()
    assert.equals("incoming_calls", deps.lsp.starts[1].action_name)
    complete(deps, 1, {})
    assert.is_nil(state.recursive)
    assert.matches("completed", last_notification(deps), nil, true)
  end)

  it("waits for a pending semantic subject before querying a recorded occurrence", function()
    local session, deps = new_session({ defer_symbols = true })
    local state = session:state()
    local reference = Fixtures.location("lua/semantic.lua", 0, "value")
    deps.lsp.auto_outcome = outcome("references", state.flow.root.id, { reference })
    session:run_action("references")
    deps.lsp.auto_outcome = nil

    local references = assert(state.flow:action_for(state.flow.root.id, "textDocument/references"))
    local reference_id = assert(state.flow:action_target_ids(references)[1])
    local enrichment_done = assert(deps.symbols.on_done)
    local anchor = {
      locator = { kind = "project", path = "lua/semantic.lua" },
      range = {
        start = { line = 0, character = 9 },
        ["end"] = { line = 0, character = 12 },
      },
      line_text = "function Bar()",
    }
    deps:add_buffer(81, "/project/lua/semantic.lua", { lines = { "function Bar()" } })
    deps.locator.open_target_result = { bufnr = 81, row = 1, col = 9 }

    session:start_recursive(row(reference_id), "callees", { depth = 1 })
    deps:flush_scheduled()
    assert.equals(1, #deps.lsp.starts)

    enrichment_done({
      [reference_id] = { symbol = "Bar", kind = "function", query_anchor = anchor },
    })
    assert.equals(2, #deps.lsp.starts)
    assert.equals("Bar", state.flow:location(reference_id).location.symbol)
    assert.same({
      uri = "file:///project/lua/semantic.lua",
      line = 0,
      character = 9,
      line_text = "function Bar()",
      encoding = "utf-8",
    }, deps.lsp.starts[2].context.stored_position)
    complete(deps, 2, {})
    assert.is_nil(state.recursive)
  end)

  it("terminates a cycle and diamond once per canonical location with bounded concurrency", function()
    local session, deps = new_session({ recursive = { concurrency = 2, depth = 4 } })
    local state = session:state()
    local root_id = state.flow.root.id
    local original_current = state.flow.current_node_id
    local original_window = vim.deepcopy(deps.windows[deps.origin_win])
    local b = Fixtures.location("lua/b.lua", 0, "B")
    local c = Fixtures.location("lua/c.lua", 0, "C")
    local d = Fixtures.location("lua/d.lua", 0, "D")

    session:start_recursive(row(root_id), "callees", { depth = 4, max_subjects = 20, concurrency = 2 })
    deps:flush_scheduled()
    complete(deps, 1, { b, c })
    deps:flush_scheduled()

    assert.equals(3, #deps.lsp.starts)
    assert.equals(2, state.request_count)
    local b_id = state.flow:action_target_ids(state.flow:action_for(root_id, Actions.get("outgoing_calls").method))[1]
    local c_id = state.flow:action_target_ids(state.flow:action_for(root_id, Actions.get("outgoing_calls").method))[2]
    assert.same({ b_id, c_id }, {
      deps.lsp.starts[2].context.origin_node_id,
      deps.lsp.starts[3].context.origin_node_id,
    })

    complete(deps, 3, { d })
    deps:flush_scheduled()
    assert.equals(3, #deps.lsp.starts)
    complete(deps, 2, { vim.deepcopy(state.flow.root.location), d })
    deps:flush_scheduled()

    assert.equals(4, #deps.lsp.starts)
    local d_id = deps.lsp.starts[4].context.origin_node_id
    assert.equals(
      state.flow:action_target_ids(state.flow:action_for(b_id, Actions.get("outgoing_calls").method))[2],
      d_id
    )
    complete(deps, 4, { b })

    assert.is_nil(state.recursive)
    assert.equals(0, state.request_count)
    assert.equals(original_current, state.flow.current_node_id)
    assert.same(original_window, deps.windows[deps.origin_win])
    assert.equals(0, #deps.sidebar.focus_relation_calls)
    assert.equals(4, #deps.lsp.starts)
  end)

  it("walks complete caches synchronously in bounded scheduled batches", function()
    local session, deps = new_session()
    local state = session:state()
    local method = Actions.get("outgoing_calls").method
    local origin_id = state.flow.root.id
    for index = 1, 8 do
      local target = Fixtures.location(string.format("lua/cache_%d.lua", index), 0, "cached" .. index)
      local commit = state.flow:commit_navigation({
        origin_node_id = origin_id,
        method = method,
        label = "calls",
        locations = { target },
        query_status = "complete",
      })
      origin_id = commit.node_id_by_identity[target.identity]
    end
    state.flow:commit_navigation({
      origin_node_id = origin_id,
      method = method,
      label = "calls",
      locations = {},
      query_status = "complete",
    })

    session:start_recursive(row(state.flow.root.id), "callees", {
      depth = 10,
      max_subjects = 20,
      concurrency = 1,
    })
    deps:flush_scheduled()

    assert.equals(4, state.recursive.processed)
    assert.equals(0, #deps.lsp.starts)
    assert.is_true(#deps.scheduled > 0)
    deps:flush_all_scheduled()
    assert.is_nil(state.recursive)
    assert.equals(0, #deps.lsp.starts)
  end)

  it("retries a partial cache, keeps its targets, and continues siblings after issues", function()
    local session, deps = new_session()
    local state = session:state()
    local method = Actions.get("outgoing_calls").method
    local b = Fixtures.location("lua/partial_b.lua", 0, "B")
    local c = Fixtures.location("lua/partial_c.lua", 0, "C")
    state.flow:commit_navigation({
      origin_node_id = state.flow.root.id,
      method = method,
      label = "calls",
      locations = { b },
      query_status = "partial",
    })

    session:start_recursive(row(state.flow.root.id), "callees", { depth = 2, concurrency = 2 })
    deps:flush_scheduled()
    assert.equals(1, #deps.lsp.starts)
    complete(deps, 1, { c }, {
      status = "partial",
      failures = { { kind = "protocol", message = "one server failed" } },
    })
    deps:flush_scheduled()

    assert.equals(3, #deps.lsp.starts)
    complete(deps, 2, {}, {
      status = "error",
      failures = { { kind = "protocol", message = "B failed" } },
    })
    complete(deps, 3, {})

    assert.equals("issues", state.recursive.state)
    assert.equals(2, state.recursive.issues)
    assert.equals(3, state.recursive.processed)
    assert.same(
      {
        Locator.location_key(b),
        Locator.location_key(c),
      },
      vim.tbl_map(function(target_id)
        return Locator.location_key(state.flow:location(target_id).location)
      end, state.flow:action_target_ids(state.flow:action_for(state.flow.root.id, method)))
    )
    assert.matches("2 issues", last_notification(deps), nil, true)
  end)

  it("continues through usable partial targets when their retry fails", function()
    local session, deps = new_session()
    local state = session:state()
    local method = Actions.get("outgoing_calls").method
    local b = Fixtures.location("lua/partial_fallback_b.lua", 0, "B")
    local c = Fixtures.location("lua/partial_fallback_c.lua", 0, "C")
    state.flow:commit_navigation({
      origin_node_id = state.flow.root.id,
      method = method,
      label = "calls",
      locations = { b, c },
      query_status = "partial",
    })

    session:start_recursive(row(state.flow.root.id), "callees", { depth = 2, concurrency = 2 })
    deps:flush_scheduled()
    complete(deps, 1, {}, {
      status = "error",
      failures = { { kind = "protocol", message = "refresh failed" } },
    })
    deps:flush_scheduled()

    assert.equals(3, #deps.lsp.starts)
    complete(deps, 2, {})
    complete(deps, 3, {})
    assert.equals("issues", state.recursive.state)
    assert.equals(3, state.recursive.processed)
  end)

  it("continues through a complete cache when a failed refresh retry fails again", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local method = Actions.get("outgoing_calls").method
    local b = Fixtures.location("lua/refresh_fallback_b.lua", 0, "B")
    state.flow:commit_navigation({
      origin_node_id = root_id,
      method = method,
      label = "calls",
      locations = { b },
      query_status = "complete",
    })
    state.relations["relation:" .. root_id .. ":" .. method] = {
      origin_id = root_id,
      method = method,
      label = "calls",
      state = "error",
      replace_targets = true,
    }

    session:start_recursive(row(root_id), "callees", { depth = 2, concurrency = 1 })
    deps:flush_scheduled()
    complete(deps, 1, {}, {
      status = "error",
      failures = { { kind = "protocol", message = "refresh failed again" } },
    })
    deps:flush_scheduled()

    assert.equals(2, #deps.lsp.starts)
    complete(deps, 2, {})
    assert.equals("issues", state.recursive.state)
    assert.equals(2, state.recursive.processed)
  end)

  it("enforces the subject allowance and resumes the same paused run", function()
    local session, deps = new_session({ recursive = { max_subjects = 2, concurrency = 4 } })
    local state = session:state()
    local root_id = state.flow.root.id
    local b = Fixtures.location("lua/pause_b.lua", 0, "B")
    local c = Fixtures.location("lua/pause_c.lua", 0, "C")
    local d = Fixtures.location("lua/pause_d.lua", 0, "D")

    local scheduler = session:start_recursive(row(root_id), "callees", { depth = 2, max_subjects = 2, concurrency = 4 })
    deps:flush_scheduled()
    complete(deps, 1, { b, c, d })
    deps:flush_scheduled()
    assert.equals(2, #deps.lsp.starts)
    complete(deps, 2, {})

    assert.equals("paused", state.recursive.state)
    assert.equals(2, state.recursive.allowance)
    local focus_count = #deps.sidebar.focus_recursive_calls
    assert.is_nil(session:start_recursive(row(root_id), "callees", {
      depth = 3,
      max_subjects = 2,
      concurrency = 4,
    }))
    assert.equals(2, state.recursive.allowance)
    assert.matches("already active", last_notification(deps), nil, true)
    assert.equals(
      scheduler,
      session:start_recursive({
        kind = "recursive",
        owner_id = root_id,
        context_location_id = root_id,
      }, "callees")
    )
    assert.equals(4, state.recursive.allowance)
    assert.equals(focus_count + 2, #deps.sidebar.focus_recursive_calls)
    deps:flush_scheduled()
    assert.equals(4, #deps.lsp.starts)
    complete(deps, 3, {})
    complete(deps, 4, {})
    assert.is_nil(state.recursive)
  end)

  it("coalesces a running invocation and rejects a different active build", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local scheduler = session:start_recursive(row(root_id), "callees")

    assert.equals(scheduler, session:start_recursive(row(root_id), "callees"))
    assert.is_nil(session:start_recursive(row(root_id), "callers"))
    assert.equals("callees", state.recursive.direction)
    assert.matches("already active", last_notification(deps), nil, true)
    assert.equals(3, #deps.sidebar.focus_recursive_calls)
    deps:flush_scheduled()
    assert.equals(1, #deps.lsp.starts)
  end)

  it("shares an exact pending request with manual navigation and detaches safely on cancellation", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local method = Actions.get("outgoing_calls").method
    local target = Fixtures.location("lua/shared.lua", 0, "shared")

    session:start_recursive(row(root_id), "callees")
    deps:flush_scheduled()
    local handle = deps.lsp.handles[1]
    assert.equals(handle, session:show_callees(row(root_id)))
    assert.equals(1, #deps.lsp.starts)
    assert.equals(1, state.request_count)

    assert.is_true(session:cancel_build())
    assert.equals("cancelled", state.recursive.state)
    assert.equals(0, #handle.cancel_calls)
    assert.equals(1, state.request_count)

    complete(deps, 1, { target })
    assert.equals(0, state.request_count)
    assert.is_table(state.flow:action_for(root_id, method))
    assert.equals("cancelled", state.recursive.state)
  end)

  it("stops a stale traversal when a consumed relation is replaced", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local method = Actions.get("outgoing_calls").method
    local b = Fixtures.location("lua/mutation_b.lua", 0, "B")
    local c = Fixtures.location("lua/mutation_c.lua", 0, "C")
    state.flow:commit_navigation({
      origin_node_id = root_id,
      method = method,
      label = "calls",
      locations = { b },
      query_status = "complete",
    })

    session:start_recursive(row(root_id), "callees", { depth = 2, concurrency = 1 })
    deps:flush_all_scheduled()
    assert.equals(1, #deps.lsp.starts)
    local b_handle = deps.lsp.handles[1]

    session:show_callees(row(root_id), true)
    assert.equals(2, #deps.lsp.starts)
    complete(deps, 2, { c })

    assert.equals("issues", state.recursive.state)
    assert.matches("flow changed", state.recursive.message, nil, true)
    assert.equals(1, #b_handle.cancel_calls)
    local root_targets = state.flow:action_target_ids(state.flow:action_for(root_id, method))
    assert.equals(1, #root_targets)
    assert.equals(Locator.location_key(c), Locator.location_key(state.flow:location(root_targets[1]).location))
    complete(deps, 1, {})
    assert.equals("issues", state.recursive.state)

    session:start_recursive(row(root_id), "callees", { depth = 2, concurrency = 1 })
    deps:flush_all_scheduled()
    assert.equals(3, #deps.lsp.starts)
    assert.equals(root_targets[1], deps.lsp.starts[3].context.origin_node_id)
    complete(deps, 3, {})
    assert.is_nil(state.recursive)
  end)

  it("stops an in-flight subject when its canonical query anchor changes", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local method = Actions.get("outgoing_calls").method
    local b = Fixtures.location("lua/retarget.lua", 0, "B")
    b.query_anchor = {
      locator = vim.deepcopy(b.locator),
      range = {
        start = { line = 0, character = 6 },
        ["end"] = { line = 0, character = 10 },
      },
      line_text = "local main = true",
    }
    local committed = state.flow:commit_navigation({
      origin_node_id = root_id,
      method = method,
      label = "calls",
      locations = { b },
      query_status = "complete",
    })
    local b_id = assert(committed.node_id_by_identity[b.identity])

    session:start_recursive(row(root_id), "callees", { depth = 2, concurrency = 1 })
    deps:flush_all_scheduled()
    assert.equals(6, deps.lsp.starts[1].context.stored_position.character)
    local b_handle = deps.lsp.handles[1]

    local retargeted = vim.deepcopy(b)
    retargeted.query_anchor.range = {
      start = { line = 0, character = 0 },
      ["end"] = { line = 0, character = 5 },
    }
    session:show_callees(row(root_id), true)
    complete(deps, 2, { retargeted })

    local target_ids = state.flow:action_target_ids(state.flow:action_for(root_id, method))
    assert.same({ b_id }, target_ids)
    assert.equals(0, state.flow:location(b_id).location.query_anchor.range.start.character)
    assert.equals(1, #b_handle.cancel_calls)
    assert.equals("issues", state.recursive.state)
    complete(deps, 1, {})
    assert.equals("issues", state.recursive.state)
  end)

  it("stops a stale traversal when save reconciliation changes a consumed relation", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local method = Actions.get("outgoing_calls").method
    local b = Fixtures.location("lua/save_b.lua", 0, "B")
    local c = Fixtures.location("lua/save_c.lua", 0, "C")
    state.flow:commit_navigation({
      origin_node_id = root_id,
      method = method,
      label = "calls",
      locations = { b },
      query_status = "complete",
    })
    session:start_recursive(row(root_id), "callees", { depth = 2, concurrency = 1 })
    deps:flush_all_scheduled()
    local b_handle = deps.lsp.handles[1]
    local save = deps.store.save
    deps.store.save = function(store, flow)
      local saved, reason = save(store, flow)
      flow:commit_navigation({
        origin_node_id = root_id,
        method = method,
        label = "calls",
        locations = { c },
        query_status = "complete",
        replace_targets = true,
      })
      return saved, reason
    end

    assert.is_true(session:save())

    assert.equals("issues", state.recursive.state)
    assert.matches("flow changed", state.recursive.message, nil, true)
    assert.equals(1, #b_handle.cancel_calls)
  end)

  it("delivers invalidation to the scheduler and cancels auto-only requests exactly once", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local method = Actions.get("outgoing_calls").method

    session:start_recursive(row(root_id), "callees")
    deps:flush_scheduled()
    local handle = deps.lsp.handles[1]
    assert.is_true(session:_invalidate_relation(state, root_id, method, "test invalidation"))

    assert.equals(1, #handle.cancel_calls)
    assert.equals(0, state.request_count)
    assert.equals("issues", state.recursive.state)
    assert.equals(1, state.recursive.issues)
    complete(deps, 1, { Fixtures.location("lua/late.lua", 0, "late") })
    assert.is_nil(state.flow:action_for(root_id, method))

    assert.is_true(session:cancel_build({ dismiss = true, silent = true }))
    session:start_recursive(row(root_id), "callees")
    deps:flush_scheduled()
    local second = deps.lsp.handles[2]
    assert.is_true(session:cancel_build())
    assert.equals(1, #second.cancel_calls)
    assert.equals(0, state.request_count)
  end)

  it("dismisses the run before structural deletion can expand queued descendants", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local method = Actions.get("outgoing_calls").method
    local b = Fixtures.location("lua/delete_b.lua", 0, "B")
    local c = Fixtures.location("lua/delete_c.lua", 0, "C")

    session:start_recursive(row(root_id), "callees", { depth = 3 })
    deps:flush_scheduled()
    complete(deps, 1, { b, c })
    local action = assert(state.flow:action_for(root_id, method))
    assert.is_true(#deps.scheduled > 0)

    assert.is_true(session:delete_row({ kind = "action", owner_id = action.id }))
    assert.is_nil(state.recursive)
    assert.is_nil(state.flow:action_for(root_id, method))
    deps:flush_all_scheduled()
    assert.equals(1, #deps.lsp.starts)

    session:start_recursive(row(root_id), "callees")
    deps:flush_scheduled()
    local handle = deps.lsp.handles[2]
    assert.is_false(session:delete_row(row(root_id)))
    assert.is_table(state.recursive)
    assert.equals(0, #handle.cancel_calls)
    assert.is_false(session:delete_row({
      kind = "relation",
      owner_id = "missing",
      context_location_id = root_id,
      method = "missing/method",
    }))
    assert.is_table(state.recursive)
    assert.equals(0, #handle.cancel_calls)
    assert.is_true(session:delete_row({
      kind = "relation",
      owner_id = "recursive-loading",
      context_location_id = root_id,
      method = method,
    }))
    assert.is_nil(state.recursive)
    assert.equals(1, #handle.cancel_calls)
    complete(deps, 2, { Fixtures.location("lua/delete_late.lua", 0, "late") })
    assert.is_nil(state.flow:action_for(root_id, method))
  end)

  it("validates runtime bounds before replacing or starting a scheduler", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    for _, case in ipairs({
      { "depth", 11 },
      { "max_subjects", 1001 },
      { "concurrency", 0 },
      { "depth", false },
    }) do
      assert.is_nil(session:start_recursive(row(root_id), "callees", { [case[1]] = case[2] }))
      assert.is_nil(state.recursive)
      assert.matches(case[1], last_notification(deps), nil, true)
    end
  end)

  it("uses the contextual sidebar row without moving logical current", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local child = Fixtures.location("lua/selected.lua", 0, "selected")
    local commit = state.flow:commit_navigation({
      origin_node_id = root_id,
      method = "textDocument/definition",
      label = "definition",
      locations = { child },
    })
    local child_id = commit.node_id_by_identity[child.identity]
    deps.sidebar.selected_row_value = row(child_id)
    deps.current_win_id = deps.sidebar.winid

    session:build({ direction = "callers", depth = 1 })
    assert.equals(child_id, state.recursive.seed_id)
    assert.equals(root_id, state.flow.current_node_id)
    deps:flush_scheduled()
    assert.equals(child_id, deps.lsp.starts[1].context.origin_node_id)
    assert.equals("incoming_calls", deps.lsp.starts[1].action_name)
  end)

  it("preserves recursive work through abandoned close and load lifecycles", function()
    local closing, close_deps = new_session()
    closing:state().flow:set_note(closing:state().flow.root.id, "dirty")
    closing:start_recursive(row(closing:state().flow.root.id), "callees")
    close_deps:flush_scheduled()
    local close_handle = close_deps.lsp.handles[1]

    assert.is_true(closing:close("test"))
    assert.is_not_nil(closing:state().recursive)
    assert.equals(0, #close_handle.cancel_calls)
    assert.equals(1, closing:state().request_count)
    assert.equals("deciding", closing:state().phase)
    close_deps.select_callback("Cancel", 3)
    assert.is_not_nil(closing:state().recursive)
    assert.equals(0, #close_handle.cancel_calls)

    assert.is_true(closing:close("test"))
    close_deps.select_callback("Discard", 2)
    assert.is_nil(closing:state().recursive)
    assert.equals(1, #close_handle.cancel_calls)
    assert.equals(0, closing:state().request_count)
    assert.equals("closed", closing:state().phase)

    local loading, load_deps = new_session()
    loading:start_recursive(row(loading:state().flow.root.id), "callers")
    load_deps:flush_scheduled()
    local load_handle = load_deps.lsp.handles[1]
    assert.is_nil(loading:load())
    assert.is_not_nil(loading:state().recursive)
    assert.equals(0, #load_handle.cancel_calls)
    assert.equals(1, loading:state().request_count)
    assert.matches("no saved flows", last_notification(load_deps), nil, true)
  end)

  it("cancels recursive work only after a loaded replacement mounts", function()
    local session, deps = new_session()
    local old_state = session:state()
    session:start_recursive(row(old_state.flow.root.id), "callers")
    deps:flush_scheduled()
    local handle = deps.lsp.handles[1]
    local entry = {
      path = "/project/.voyager/flows/loaded.json",
      name = "loaded",
      display_path = "lua/loaded.lua",
      updated_at = "now",
    }
    local loaded = Fixtures.new_flow()
    deps.store.entries = { entry }
    deps.store.load_result = loaded
    deps.next_sidebar = deps:new_sidebar()
    deps.next_lsp = deps:new_lsp()

    assert.is_true(session:load())
    assert.equals(0, #handle.cancel_calls)
    deps.select_callback(entry, 1)

    assert.equals(loaded, session:state().flow)
    assert.is_nil(old_state.recursive)
    assert.equals(1, #handle.cancel_calls)
    assert.equals(0, session:state().request_count)
  end)

  it("keeps recursive work when a loaded replacement cannot mount", function()
    local session, deps = new_session()
    local state = session:state()
    session:start_recursive(row(state.flow.root.id), "callers")
    deps:flush_scheduled()
    local handle = deps.lsp.handles[1]
    local entry = {
      path = "/project/.voyager/flows/broken.json",
      name = "broken",
      display_path = "lua/broken.lua",
      updated_at = "now",
    }
    deps.store.entries = { entry }
    deps.store.load_result = Fixtures.new_flow()
    local loaded_sidebar = deps:new_sidebar()
    loaded_sidebar.mount_result = false
    loaded_sidebar.mount_error = "editor too narrow"
    deps.next_sidebar = loaded_sidebar
    deps.next_lsp = deps:new_lsp()

    assert.is_true(session:load())
    deps.select_callback(entry, 1)

    assert.equals(state, session:state())
    assert.is_not_nil(state.recursive)
    assert.equals(0, #handle.cancel_calls)
    assert.equals(1, state.request_count)
  end)
end)
