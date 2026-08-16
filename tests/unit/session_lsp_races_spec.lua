local Actions = require("voyager.lsp.actions")
local FakeSessionDeps = require("tests.helpers.fake_session_deps")
local Fixtures = require("tests.helpers.flow")
local Locator = require("voyager.locator")
local Session = require("voyager.session")

local function new_session()
  local deps = FakeSessionDeps.new()
  local session = Session.new(deps:session_options())
  assert.is_true(session:open())
  assert.is_true(session:ensure_flow())
  return session, deps
end

local function outcome(action_name, origin_node_id, locations, opts)
  opts = opts or {}
  local action = Actions.get(action_name)
  local items = {}
  for _, location in ipairs(locations or {}) do
    table.insert(items, {
      identity = location.identity or Locator.location_key(location),
      location = vim.deepcopy(location),
      raw = { uri = location.locator.path or location.locator.uri },
      list_item = {
        filename = "/project/" .. location.locator.path,
        lnum = location.range.start.line + 1,
        col = location.range.start.character + 1,
        end_lnum = location.range["end"].line + 1,
        end_col = location.range["end"].character + 1,
        text = location.context or "",
      },
    })
  end
  return {
    status = opts.status or "success",
    action = action,
    method = action.method,
    label = action.label,
    origin_node_id = origin_node_id,
    items = items,
    locations = vim.deepcopy(locations or {}),
    failures = vim.deepcopy(opts.failures or {}),
  }
end

describe("Voyager asynchronous navigation orchestration", function()
  it("captures immutable invocation-time editor and logical-origin data", function()
    local session, deps = new_session()
    session:run_action("definition")
    local context = deps.lsp.starts[1].context

    assert.equals(session:state().generation, context.generation)
    assert.equals(session:state().flow.flow_id, context.flow_id)
    assert.equals(1, context.request_token)
    assert.equals(deps.root_id, context.origin_node_id)
    assert.equals(deps.origin_buf, context.bufnr)
    assert.equals(deps.origin_win, context.winid)
    assert.equals(deps.project_root, context.project_root)
    assert.equals(deps.config.navigation.timeout_ms, context.timeout_ms)
    assert.same({ line = 0, character = 6 }, context.cursor)
    assert.same({ kind = "project", path = "lua/main.lua" }, context.cursor_locator)
    assert.same({
      start = { line = 0, character = 6 },
      ["end"] = { line = 0, character = 10 },
    }, context.cursor_range)
    assert.is_nil(context.manual_location)

    deps:set_cursor(0, "changed", 0, 7)
    assert.same({ line = 0, character = 6 }, context.cursor)
  end)

  it("settles a synchronous completion before storing its handle", function()
    local session, deps = new_session()
    local root_id = session:state().flow.root.id
    local result = Fixtures.location("lua/auth.lua", 0, "authorize")
    deps.lsp.auto_outcome = outcome("definition", root_id, { result })
    local render_count_before = deps.sidebar.render_count

    session:run_action("definition")

    assert.equals(0, session:state().request_count)
    assert.equals(1, #session:state().flow.root.actions)
    assert.is_nil(session:state().request_handles[1])
    assert.equals(render_count_before + 2, deps.sidebar.render_count)
    local claim = session:state().destination_claim
    assert.is_table(claim)
    assert.equals(1, claim.request_token)
    assert.equals(1, #claim.targets)
    assert.is_string(claim.targets[1].node_id)
    assert.equals("/project/lua/auth.lua", claim.targets[1].filename)
    assert.equals(1, claim.targets[1].lnum)
    assert.equals(1, claim.targets[1].col)
  end)

  it("enriches committed nodes with enclosing symbols and re-renders on results", function()
    local session, deps = new_session()
    local root_id = session:state().flow.root.id
    local result = Fixtures.location("lua/auth.lua", 0, "authorize")
    deps.lsp.auto_outcome = outcome("references", root_id, { result })
    session:run_action("references")

    -- resolve_calls[1] is the root enrichment from flow creation
    local call = deps.symbols.resolve_calls[2]
    assert.is_table(call)
    assert.equals(1, #call.requests)
    assert.equals("file:///project/lua/auth.lua", call.requests[1].uri)
    assert.equals(deps.config.navigation.timeout_ms, call.opts.timeout_ms)
    local node_id = call.requests[1].node_id
    local anchor = {
      locator = { kind = "project", path = "lua/auth.lua" },
      range = {
        start = { line = 0, character = 9 },
        ["end"] = { line = 0, character = 18 },
      },
      line_text = "function authorize()",
    }

    local renders = deps.sidebar.render_count
    deps.symbols.on_done({
      [node_id] = { symbol = "AuthService.authorize", kind = "method", query_anchor = anchor },
    })
    local node = session:state().flow:location(node_id)
    assert.equals("AuthService.authorize", node.location.symbol)
    assert.equals("method", node.location.symbol_kind)
    assert.same(anchor, node.location.query_anchor)
    assert.equals(renders + 1, deps.sidebar.render_count)

    deps.symbols.on_done({
      [node_id] = { symbol = "AuthService.authorize", kind = "method", query_anchor = anchor },
    })
    assert.equals(renders + 1, deps.sidebar.render_count)
  end)

  it("drops enrichment results that settle after the session closes", function()
    local session, deps = new_session()
    local root_id = session:state().flow.root.id
    local result = Fixtures.location("lua/auth.lua", 0, "authorize")
    deps.lsp.auto_outcome = outcome("references", root_id, { result })
    session:run_action("references")
    local node_id = deps.symbols.resolve_calls[2].requests[1].node_id
    local flow = session:state().flow

    session:shutdown()
    deps.symbols.on_done({ [node_id] = { symbol = "Late.symbol", kind = "method" } })
    assert.equals("authorize", flow:location(node_id).location.symbol)
  end)

  it("returns current to an ancestor when navigation retraces the route", function()
    local session, deps = new_session()
    local root_id = deps.root_id
    local site = Fixtures.location("lua/site.lua", 0, "site")
    local commit = session:state().flow:commit_navigation({
      origin_node_id = root_id,
      method = "textDocument/references",
      label = "references",
      locations = { site },
    })
    local site_id = commit.node_id_by_identity[site.identity]
    assert.is_true(session:state().flow:set_current(site_id))

    deps:add_buffer(61, "/project/lua/site.lua", { lines = { "site" } })
    deps.windows[deps.origin_win].bufnr = 61
    deps:set_cursor(0, "site", 0, 4)

    local back = vim.deepcopy(session:state().flow.root.location)
    back.identity = Locator.location_key(back)
    deps.lsp.auto_outcome = outcome("definition", site_id, { back })
    session:run_action("definition")

    local reverse = session:state().flow:action_for(site_id, "textDocument/definition")
    assert.is_table(reverse)
    assert.same({}, reverse.results)
    assert.same({ root_id }, session:state().flow:action_target_ids(reverse))
    local claim = session:state().destination_claim
    assert.is_table(claim)
    assert.equals(root_id, claim.targets[1].node_id)

    deps.windows[deps.origin_win].bufnr = deps.origin_buf
    deps.windows[deps.origin_win].cursor = { 1, back.range.start.character }
    deps:trigger("CursorMoved")
    assert.equals(root_id, session:state().flow.current_node_id)
  end)

  it("moves current when the cursor lands on a claimed destination", function()
    local session, deps = new_session()
    local root_id = session:state().flow.root.id
    local first = Fixtures.location("lua/def-a.lua", 4)
    local twin = Fixtures.location("lua/def-a.lua", 4)
    twin.range = {
      start = { line = 4, character = 10 },
      ["end"] = { line = 4, character = 14 },
    }
    twin.identity = Locator.location_key(twin)
    local second = Fixtures.location("lua/def-b.lua", 9)
    deps.lsp.auto_outcome = outcome("references", root_id, { first, twin, second })
    session:run_action("references")
    local claim = session:state().destination_claim
    assert.is_table(claim)
    assert.equals(3, #claim.targets)

    deps:add_buffer(51, "/project/lua/def-a.lua")
    deps:add_buffer(52, "/project/lua/def-b.lua")

    deps.current_win_id = deps.sidebar.winid
    deps:trigger("CursorMoved")
    assert.equals(root_id, session:state().flow.current_node_id)

    deps.current_win_id = deps.origin_win
    deps.windows[deps.origin_win].bufnr = 51
    deps.windows[deps.origin_win].cursor = { 6, 0 }
    deps:trigger("CursorMoved")
    assert.equals(root_id, session:state().flow.current_node_id)

    deps.windows[deps.origin_win].cursor = { 5, 7 }
    deps:trigger("CursorMoved")
    assert.equals(root_id, session:state().flow.current_node_id, "two destinations on the line stay ambiguous")

    deps.windows[deps.origin_win].cursor = { 5, 2 }
    deps:trigger("CursorMoved")
    assert.equals(claim.targets[1].node_id, session:state().flow.current_node_id, "containment resolves the column")
    assert.is_table(session:state().destination_claim)

    deps.windows[deps.origin_win].cursor = { 5, 10 }
    deps:trigger("CursorMoved")
    assert.equals(claim.targets[2].node_id, session:state().flow.current_node_id, "exact column wins")

    deps.windows[deps.origin_win].bufnr = 52
    deps.windows[deps.origin_win].cursor = { 10, 6 }
    deps:trigger("CursorMoved")
    assert.equals(claim.targets[3].node_id, session:state().flow.current_node_id, "unique line match tolerates column")

    assert.is_true(session:set_current(root_id))
    assert.is_nil(session:state().destination_claim)
    deps.windows[deps.origin_win].bufnr = 51
    deps.windows[deps.origin_win].cursor = { 5, 0 }
    deps:trigger("CursorMoved")
    assert.equals(
      claim.targets[1].node_id,
      session:state().flow.current_node_id,
      "ordinary active-symbol tracking resumes after the claim is cleared"
    )
  end)

  it("settles every logical status exactly once", function()
    local cases = {
      { status = "success", commit = true, locations = { Fixtures.location("lua/success.lua", 0) } },
      {
        status = "partial",
        commit = true,
        locations = { Fixtures.location("lua/partial.lua", 0) },
        failures = {
          { kind = "protocol", client_name = "fake", client_id = 1, message = "partial failure" },
        },
      },
      { status = "empty", commit = true, locations = {} },
      { status = "error", commit = false, locations = { Fixtures.location("lua/error.lua", 0) } },
      { status = "timeout", commit = false, locations = {} },
      { status = "unsupported", commit = false, locations = {} },
      { status = "cancelled", commit = false, locations = {} },
      { status = "superseded", commit = false, locations = {} },
    }

    for _, case in ipairs(cases) do
      local session, deps = new_session()
      local root_id = session:state().flow.root.id
      deps.lsp.auto_outcome = outcome("definition", root_id, case.locations, {
        status = case.status,
        failures = case.failures,
      })
      deps.lsp.complete_twice = true
      local renders = deps.sidebar.render_count
      session:run_action("definition")

      assert.equals(0, session:state().request_count, case.status)
      assert.equals(renders + 2, deps.sidebar.render_count, case.status)
      assert.equals(case.commit and 1 or 0, #session:state().flow.root.actions, case.status)
      assert.is_nil(session:state().request_handles[1], case.status)
      local expects_claim = case.commit and #case.locations > 0
      assert.equals(expects_claim, session:state().destination_claim ~= nil, case.status)
    end
  end)

  it("settles a thrown LSP start through the same path", function()
    local session, deps = new_session()
    deps.lsp.start_error = "setup exploded"
    local renders = deps.sidebar.render_count
    session:run_action("definition")
    assert.equals(0, session:state().request_count)
    assert.equals(renders + 2, deps.sidebar.render_count)
    assert.equals(0, #session:state().flow.root.actions)
    assert.matches("setup exploded", deps.notifications[#deps.notifications].message, nil, true)
  end)

  it("stores only live handles and settles a pending request later", function()
    local session, deps = new_session()
    session:run_action("definition")
    assert.equals(1, session:state().request_count)
    assert.equals(deps.lsp.handles[1], session:state().request_handles[1])
    assert.equals(0, #session:state().flow.root.actions)

    local result = Fixtures.location("lua/later.lua", 0)
    deps.lsp:complete(1, outcome("definition", deps.lsp.starts[1].context.origin_node_id, { result }))
    assert.equals(0, session:state().request_count)
    assert.is_nil(session:state().request_handles[1])
    assert.equals(1, #session:state().flow.root.actions)
  end)

  it("commits a staged manual connector atomically and lets the destination claim take over", function()
    local session, deps = new_session()
    deps:set_cursor(0, "local", 0, 5)
    session:run_action("definition")
    local context = deps.lsp.starts[1].context
    assert.is_not_nil(context.manual_location)
    assert.equals(Locator.location_key(context.manual_location), context.manual_location.identity)
    assert.equals(0, #session:state().flow.root.actions)

    local result = Fixtures.location("lua/manual-result.lua", 0)
    deps.lsp:complete(1, outcome("definition", context.origin_node_id, { result }))

    local manual = session:state().flow.root.actions[1]
    assert.equals("voyager/manual", manual.method)
    assert.equals(1, #manual.results)
    assert.equals("textDocument/definition", manual.results[1].actions[1].method)
    assert.equals(manual.results[1].id, session:state().flow.current_node_id)

    local claim = session:state().destination_claim
    assert.is_table(claim)
    deps:add_buffer(41, "/project/lua/manual-result.lua")
    deps.windows[deps.origin_win].bufnr = 41
    deps.windows[deps.origin_win].cursor = { 1, 0 }
    deps:trigger("CursorMoved")
    assert.equals(claim.targets[1].node_id, session:state().flow.current_node_id)
  end)

  it("leaves a committed manual origin current when the action is empty", function()
    local session, deps = new_session()
    deps:set_cursor(0, "local", 0, 5)
    session:run_action("definition")
    local context = deps.lsp.starts[1].context
    deps.lsp:complete(1, outcome("definition", context.origin_node_id, {}, { status = "empty" }))

    local manual_action = session:state().flow.root.actions[1]
    local manual = manual_action.results[1]
    assert.equals("voyager/manual", manual_action.method)
    assert.equals(1, #manual.actions)
    assert.equals(0, #manual.actions[1].results)
    assert.equals(manual.id, session:state().flow.current_node_id)
    assert.is_nil(session:state().destination_claim)
  end)

  it("does not let an older manual claim move current after a newer action", function()
    local session, deps = new_session()
    deps:set_cursor(0, "local", 0, 5)
    session:run_action("definition")
    session:run_action("implementation")

    local older = deps.lsp.starts[1].context
    deps.lsp:complete(
      1,
      outcome("definition", older.origin_node_id, {
        Fixtures.location("lua/older.lua", 0),
      })
    )
    assert.equals(deps.root_id, session:state().flow.current_node_id)
    assert.is_nil(session:state().destination_claim)
    assert.equals("voyager/manual", session:state().flow.root.actions[1].method)

    local newer = deps.lsp.starts[2].context
    deps.lsp:complete(2, outcome("implementation", newer.origin_node_id, {}, { status = "error" }))
    assert.equals(deps.root_id, session:state().flow.current_node_id)
  end)

  it("invalidates a pending manual claim on an explicit current change", function()
    local session, deps = new_session()
    local existing = Fixtures.location("lua/existing.lua", 0)
    local existing_commit = session:state().flow:commit_navigation({
      origin_node_id = deps.root_id,
      method = "textDocument/references",
      label = "references",
      locations = { existing },
    })
    local existing_id = existing_commit.node_id_by_identity[existing.identity]

    deps:set_cursor(0, "local", 0, 5)
    session:run_action("definition")
    local context = deps.lsp.starts[1].context
    local renders = deps.sidebar.render_count
    assert.is_true(session:set_current(existing_id))
    assert.equals(renders + 1, deps.sidebar.render_count)
    assert.is_false(session:set_current(existing_id))
    assert.equals(renders + 1, deps.sidebar.render_count)
    assert.is_false(session:set_current(session:state().flow.root.actions[1].id))

    deps.lsp:complete(
      1,
      outcome("definition", context.origin_node_id, {
        Fixtures.location("lua/late-manual.lua", 0),
      })
    )
    assert.equals(existing_id, session:state().flow.current_node_id)
    assert.is_table(session:state().destination_claim)
  end)

  it("keeps a manual connector entirely absent on failure", function()
    local session, deps = new_session()
    deps:set_cursor(0, "local", 0, 5)
    session:run_action("definition")
    local context = deps.lsp.starts[1].context
    deps.lsp:complete(1, outcome("definition", context.origin_node_id, {}, { status = "error" }))
    assert.equals(0, #session:state().flow.root.actions)
  end)

  it("records overlapping branches but tracks destinations only for the newest token", function()
    for _, order in ipairs({ "newest_first", "oldest_first" }) do
      local session, deps = new_session()
      session:run_action("definition")
      session:run_action("implementation")
      assert.equals(2, session:state().request_count)
      assert.equals(1, deps.lsp.handles[1].supersede_calls)
      assert.same({ 1, 2 }, {
        deps.sidebar.render_calls[#deps.sidebar.render_calls - 1].status.request_count,
        deps.sidebar.render_calls[#deps.sidebar.render_calls].status.request_count,
      })

      local first = outcome("definition", deps.lsp.starts[1].context.origin_node_id, {
        Fixtures.location("lua/definition.lua", 0),
      })
      local second = outcome("implementation", deps.lsp.starts[2].context.origin_node_id, {
        Fixtures.location("lua/implementation.lua", 0),
      })
      if order == "newest_first" then
        deps.lsp:complete(2, second)
        assert.equals(1, session:state().request_count)
        deps.lsp:complete(1, first)
      else
        deps.lsp:complete(1, first)
        assert.equals(1, session:state().request_count)
        deps.lsp:complete(2, second)
      end

      assert.equals(0, session:state().request_count)
      assert.equals(2, #session:state().flow.root.actions)
      local claim = session:state().destination_claim
      assert.is_table(claim)
      assert.equals(2, claim.request_token)
      assert.equals("/project/lua/implementation.lua", claim.targets[1].filename)
    end
  end)

  it("lets interactive supersession settle before dispatching the newer request", function()
    local session, deps = new_session()
    session:run_action("incoming_calls")
    local older_context = deps.lsp.starts[1].context
    deps.lsp.handles[1].on_supersede = function()
      deps.lsp:complete(
        1,
        outcome("incoming_calls", older_context.origin_node_id, {}, {
          status = "superseded",
        })
      )
    end

    session:run_action("definition")
    assert.equals(1, session:state().request_count)
    assert.is_nil(session:state().request_handles[1])
    assert.equals(deps.lsp.handles[2], session:state().request_handles[2])
    assert.same({ 0, 1 }, {
      deps.sidebar.render_calls[#deps.sidebar.render_calls - 1].status.request_count,
      deps.sidebar.render_calls[#deps.sidebar.render_calls].status.request_count,
    })
    assert.equals(0, #session:state().flow.root.actions)
  end)

  it("rejects completion after close and cancels the pending provider", function()
    local session, deps = new_session()
    session:run_action("definition")
    local callback = deps.lsp.starts[1].callback
    local root_id = session:state().flow.root.id
    session:close("command")
    assert.same({ "command" }, deps.lsp.handles[1].cancel_calls)
    callback(outcome("definition", root_id, { Fixtures.location("lua/late.lua", 0) }))
    assert.equals("closed", session:state().phase)
    assert.equals(0, session:state().request_count)
    assert.equals(0, #session:state().flow.root.actions)
    assert.is_nil(session:state().destination_claim)
  end)
end)
