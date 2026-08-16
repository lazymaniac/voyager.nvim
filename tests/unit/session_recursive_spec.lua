local Actions = require("voyager.lsp.actions")
local FakeSessionDeps = require("tests.helpers.fake_session_deps")
local Fixtures = require("tests.helpers.flow")
local Locator = require("voyager.locator")
local Session = require("voyager.session")

local function new_session(opts)
  opts = opts or {}
  local deps = FakeSessionDeps.new()
  deps.config.navigation.concurrency = opts.concurrency or deps.config.navigation.concurrency
  deps.symbols.auto_results = {}
  local session = Session.new(deps:session_options())
  assert.is_true(session:open())
  return session, deps
end

local function call_location(location)
  local value = vim.deepcopy(location)
  if type(value.query_anchor) ~= "table" then
    value.query_anchor = {
      locator = vim.deepcopy(value.locator),
      range = vim.deepcopy(value.range),
      line_text = "local main = true",
    }
  end
  value.identity = Locator.location_key(value)
  return value
end

local function outcome(action_name, origin_id, locations, opts)
  opts = opts or {}
  local action = Actions.get(action_name)
  local items = {}
  local normalized_locations = {}
  for _, location in ipairs(locations or {}) do
    location = call_location(location)
    table.insert(items, {
      identity = location.identity or Locator.location_key(location),
      location = vim.deepcopy(location),
      raw = {},
    })
    table.insert(normalized_locations, location)
  end
  return {
    status = opts.status or (#items > 0 and "success" or "empty"),
    action = action,
    method = action.method,
    label = action.label,
    origin_node_id = origin_id,
    items = items,
    locations = normalized_locations,
    failures = vim.deepcopy(opts.failures or {}),
  }
end

local function complete(deps, index, locations, opts)
  local start = assert(deps.lsp.starts[index])
  deps.lsp:complete(index, outcome(start.action_name, start.context.origin_node_id, locations, opts))
end

local function external_location(path, symbol)
  local location = Fixtures.location("lua/callsite-" .. path, 0, symbol)
  location.query_anchor = {
    locator = { kind = "absolute", path = "/dependencies/" .. path },
    range = vim.deepcopy(location.range),
    line_text = "external symbol",
  }
  location.identity = Locator.location_key(location)
  return location
end

describe("Voyager automatic call-graph creation", function()
  it("captures the cursor root on open and immediately seeds callers and callees", function()
    local session, deps = new_session()
    local state = session:state()

    assert.is_table(state.flow)
    assert.equals("main", state.flow.root.location.symbol)
    assert.equals(state.flow.root.id, state.flow.current_node_id)
    assert.equals(state.flow.root.id, state.graph_build.seed_id)
    assert.equals(2, state.graph_build.scheduled)
    assert.is_nil(deps.autocmds.LspRequest)
    assert.is_true(deps.sidebar.render_calls[#deps.sidebar.render_calls].status.center_current)

    deps:flush_scheduled()
    assert.equals(2, #deps.lsp.starts)
    assert.same({ "incoming_calls", "outgoing_calls" }, {
      deps.lsp.starts[1].action_name,
      deps.lsp.starts[2].action_name,
    })
    for _, start in ipairs(deps.lsp.starts) do
      assert.is_true(start.context.project_only)
      assert.is_true(start.context.automatic)
      assert.equals(state.flow.root.id, start.context.origin_node_id)
    end

    complete(deps, 1, {})
    complete(deps, 2, {})
    assert.is_nil(state.graph_build)
    assert.equals(0, state.request_count)
  end)

  it("keeps incoming descendants on the caller frontier and outgoing descendants on the callee frontier", function()
    local session, deps = new_session()
    local state = session:state()
    local original_window = vim.deepcopy(deps.windows[deps.origin_win])
    local caller = Fixtures.location("lua/caller.lua", 0, "caller")
    local callee = Fixtures.location("lua/callee.lua", 0, "callee")

    deps:flush_scheduled()
    complete(deps, 2, { callee })
    complete(deps, 1, { caller })
    deps:flush_all_scheduled()

    assert.equals(4, #deps.lsp.starts)
    assert.same({ "outgoing_calls", "incoming_calls" }, {
      deps.lsp.starts[3].action_name,
      deps.lsp.starts[4].action_name,
    })
    local outgoing = assert(state.flow:action_for(state.flow.root.id, Actions.get("outgoing_calls").method))
    local incoming = assert(state.flow:action_for(state.flow.root.id, Actions.get("incoming_calls").method))
    assert.equals(state.flow:action_target_ids(outgoing)[1], deps.lsp.starts[3].context.origin_node_id)
    assert.equals(state.flow:action_target_ids(incoming)[1], deps.lsp.starts[4].context.origin_node_id)

    complete(deps, 3, {})
    complete(deps, 4, {})
    assert.is_nil(state.graph_build)
    assert.equals(state.flow.root.id, state.flow.current_node_id)
    assert.same(original_window, deps.windows[deps.origin_win])
  end)

  it("filters external semantic locations before commit and traversal", function()
    local session, deps = new_session()
    local state = session:state()
    local external = external_location("library.lua", "library")
    local project = Fixtures.location("lua/project.lua", 0, "project")

    deps:flush_scheduled()
    complete(deps, 1, { external })
    complete(deps, 2, { project })
    deps:flush_all_scheduled()

    assert.equals(3, #deps.lsp.starts)
    assert.equals("outgoing_calls", deps.lsp.starts[3].action_name)
    local incoming = assert(state.flow:action_for(state.flow.root.id, Actions.get("incoming_calls").method))
    assert.same({}, state.flow:action_target_ids(incoming))
    assert.equals(2, #vim.tbl_filter(function(node)
      return node.kind == "location"
    end, state.flow:dfs()))

    complete(deps, 3, {})
    assert.is_nil(state.graph_build)
  end)

  it("prunes external and unverifiable targets supplied by a cached relation", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local incoming = Actions.get("incoming_calls")
    local outgoing = Actions.get("outgoing_calls")
    local external = external_location("cached.lua", "external")
    local legacy = Fixtures.location("lua/legacy-callsite.lua", 0, "legacy external")
    local project = call_location(Fixtures.location("lua/cached.lua", 0, "project"))

    local cached = state.flow:commit_navigation({
      origin_node_id = root_id,
      method = incoming.method,
      label = incoming.label,
      locations = { external, legacy, project },
      query_status = "complete",
    })
    local external_id = cached.node_id_by_identity[external.identity]
    local legacy_id = cached.node_id_by_identity[legacy.identity]
    state.flow:commit_navigation({
      origin_node_id = root_id,
      method = outgoing.method,
      label = outgoing.label,
      locations = {},
      query_status = "complete",
    })

    deps:flush_all_scheduled()
    local cached_incoming = assert(state.flow:action_for(root_id, incoming.method))
    assert.same(
      { project.identity },
      vim.tbl_map(function(target_id)
        return Locator.location_key(state.flow:location(target_id).location)
      end, state.flow:action_target_ids(cached_incoming))
    )
    assert.is_nil(state.flow:location(external_id))
    assert.is_nil(state.flow:location(legacy_id))
    assert.equals(1, #deps.lsp.starts)
    assert.equals("incoming_calls", deps.lsp.starts[1].action_name)
    local target = state.flow:location(deps.lsp.starts[1].context.origin_node_id)
    assert.equals("project", target.location.locator.kind)
    complete(deps, 1, {})
    assert.is_nil(state.graph_build)
  end)

  it("honors the relation-query concurrency cap across both frontiers", function()
    local session, deps = new_session({ concurrency = 1 })
    local state = session:state()

    deps:flush_all_scheduled()
    assert.equals(1, #deps.lsp.starts)
    assert.equals(1, state.request_count)
    complete(deps, 1, {})
    deps:flush_all_scheduled()
    assert.equals(2, #deps.lsp.starts)
    assert.equals(1, state.request_count)
    complete(deps, 2, {})
    assert.is_nil(state.graph_build)
    assert.equals(0, state.request_count)
  end)

  it("keeps partial work and reaches a terminal issues state without blocking the other frontier", function()
    local session, deps = new_session()
    local state = session:state()
    local callee = Fixtures.location("lua/survives.lua", 0, "survives")

    deps:flush_scheduled()
    complete(deps, 1, {}, {
      status = "timeout",
      failures = { { kind = "timeout", message = "timed out" } },
    })
    complete(deps, 2, { callee })
    deps:flush_all_scheduled()
    assert.equals(3, #deps.lsp.starts)
    complete(deps, 3, {})

    assert.equals("issues", state.graph_build.state)
    assert.equals(1, state.graph_build.issues)
    assert.equals(0, state.request_count)
    assert.matches("completed with 1 issue", state.graph_build.message, nil, true)
  end)

  it("cancels only when a dirty close is actually accepted and ignores late completions", function()
    local session, deps = new_session()
    local state = session:state()
    state.flow:set_note(state.flow.root.id, "dirty")
    deps:flush_scheduled()
    local first = deps.lsp.handles[1]
    local second = deps.lsp.handles[2]

    assert.is_true(session:close("test"))
    assert.equals("deciding", state.phase)
    assert.equals(0, #first.cancel_calls)
    assert.equals(0, #second.cancel_calls)
    deps.select_callback("Cancel", 3)
    assert.is_table(state.graph_build)

    assert.is_true(session:close("test"))
    deps.select_callback("Discard", 2)
    assert.equals("closed", state.phase)
    assert.is_nil(state.graph_build)
    assert.equals(1, #first.cancel_calls)
    assert.equals(1, #second.cancel_calls)
    assert.equals(0, state.request_count)

    complete(deps, 1, { Fixtures.location("lua/late.lua", 0, "late") })
    complete(deps, 2, { Fixtures.location("lua/late2.lua", 0, "late2") })
    assert.equals(1, #state.flow:dfs())
  end)

  it("reveals the canonical path whenever the active symbol changes", function()
    local session, deps = new_session()
    local state = session:state()
    deps:flush_scheduled()
    complete(deps, 1, {})
    complete(deps, 2, {})

    local location = Fixtures.location("lua/active.lua", 0, "active")
    local action = Actions.get("outgoing_calls")
    local commit = state.flow:commit_navigation({
      origin_node_id = state.flow.root.id,
      method = action.method,
      label = action.label,
      locations = { location },
      query_status = "complete",
    })
    local child_id = commit.node_id_by_identity[location.identity]
    state.flow:set_collapsed(commit.action_id, true)
    state.expanded_test_groups[commit.action_id] = nil

    assert.is_true(session:set_current(child_id))
    assert.is_false(state.flow:find(commit.action_id).collapsed)
    assert.is_true(state.expanded_test_groups[commit.action_id])
    assert.equals(child_id, state.flow.current_node_id)
  end)
end)
