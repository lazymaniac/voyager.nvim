local Actions = require("voyager.lsp.actions")
local FakeSessionDeps = require("tests.helpers.fake_session_deps")
local Fixtures = require("tests.helpers.flow")
local Locator = require("voyager.locator")
local Session = require("voyager.session")

local function new_session()
  local deps = FakeSessionDeps.new()
  local session = Session.new(deps:session_options())
  assert.is_true(session:open())
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
        filename = location.locator.path,
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
    assert.same({ deps.origin_buf, 1, 7, 0 }, context.from)
    assert.equals("main", context.tagname)
    assert.is_nil(context.manual_location)

    deps:set_cursor(0, "changed", 0, 7)
    assert.same({ line = 0, character = 6 }, context.cursor)
    assert.equals("main", context.tagname)
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
    assert.equals(1, #deps.presenter.present_calls)
    assert.equals(1, #deps.presenter.present_calls[1].items)
    assert.is_string(deps.presenter.present_calls[1].items[1].node_id)
  end)

  it("settles every logical status exactly once", function()
    local cases = {
      { status = "success", commit = true, locations = { Fixtures.location("lua/success.lua", 0) } },
      { status = "partial", commit = true, locations = { Fixtures.location("lua/partial.lua", 0) }, failures = {
        { kind = "protocol", client_name = "fake", client_id = 1, message = "partial failure" },
      } },
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
      assert.equals(case.commit and #case.locations > 0 and 1 or 0, #deps.presenter.present_calls, case.status)
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

  it("commits a staged manual connector atomically and lets presentation claim the result", function()
    local session, deps = new_session()
    deps:set_cursor(0, "local", 0, 5)
    session:run_action("definition")
    local context = deps.lsp.starts[1].context
    assert.is_not_nil(context.manual_location)
    assert.equals(Locator.location_key(context.manual_location), context.manual_location.identity)
    assert.equals(0, #session:state().flow.root.actions)

    local result = Fixtures.location("lua/manual-result.lua", 0)
    deps.presenter.on_present = function(_, items)
      local manual = session:state().flow.root.actions[1].results[1]
      assert.equals(manual.id, session:state().flow.current_node_id)
      session:set_current(items[1].node_id)
    end
    deps.lsp:complete(1, outcome("definition", context.origin_node_id, { result }))

    local manual = session:state().flow.root.actions[1]
    assert.equals("voyager/manual", manual.method)
    assert.equals(1, #manual.results)
    assert.equals("textDocument/definition", manual.results[1].actions[1].method)
    assert.equals(deps.presenter.present_calls[1].items[1].node_id, session:state().flow.current_node_id)
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
    assert.equals(0, #deps.presenter.present_calls)
  end)

  it("does not let an older manual claim move current after a newer action", function()
    local session, deps = new_session()
    deps:set_cursor(0, "local", 0, 5)
    session:run_action("definition")
    session:run_action("implementation")

    local older = deps.lsp.starts[1].context
    deps.lsp:complete(1, outcome("definition", older.origin_node_id, {
      Fixtures.location("lua/older.lua", 0),
    }))
    assert.equals(deps.root_id, session:state().flow.current_node_id)
    assert.equals(0, #deps.presenter.present_calls)
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

    deps.lsp:complete(1, outcome("definition", context.origin_node_id, {
      Fixtures.location("lua/late-manual.lua", 0),
    }))
    assert.equals(existing_id, session:state().flow.current_node_id)
    assert.equals(1, #deps.presenter.present_calls)
  end)

  it("keeps a manual connector entirely absent on failure", function()
    local session, deps = new_session()
    deps:set_cursor(0, "local", 0, 5)
    session:run_action("definition")
    local context = deps.lsp.starts[1].context
    deps.lsp:complete(1, outcome("definition", context.origin_node_id, {}, { status = "error" }))
    assert.equals(0, #session:state().flow.root.actions)
  end)

  it("records overlapping branches but presents only the newest token", function()
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
      assert.equals(1, #deps.presenter.present_calls)
      assert.equals(2, deps.presenter.present_calls[1].context.request_token)
    end
  end)

  it("lets interactive supersession settle before dispatching the newer request", function()
    local session, deps = new_session()
    session:run_action("incoming_calls")
    local older_context = deps.lsp.starts[1].context
    deps.lsp.handles[1].on_supersede = function()
      deps.lsp:complete(1, outcome("incoming_calls", older_context.origin_node_id, {}, {
        status = "superseded",
      }))
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
    assert.equals(0, #deps.presenter.present_calls)
  end)
end)
