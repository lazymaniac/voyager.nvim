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
      raw = {},
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

local function row(node_id)
  return { kind = "location", owner_id = node_id, context_location_id = node_id }
end

describe("Voyager directional call navigation", function()
  it("queries a stored location without jumping or mutating logical current", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local original_window = vim.deepcopy(deps.windows[deps.origin_win])
    local original_current = state.flow.current_node_id
    local original_tracking = state.tracking_token
    local existing_claim = { sentinel = true }
    state.destination_claim = existing_claim

    local handle = session:show_callers(row(root_id))

    assert.is_table(handle)
    assert.equals(1, #deps.lsp.starts)
    assert.equals("incoming_calls", deps.lsp.starts[1].action_name)
    assert.same({ list = false }, deps.locator.open_target_opts_calls[1])
    local context = deps.lsp.starts[1].context
    assert.is_true(context.directional)
    assert.equals(root_id, context.origin_node_id)
    assert.equals(deps.origin_buf, context.bufnr)
    assert.same({
      uri = "file:///project/lua/main.lua",
      line = 0,
      character = 6,
      line_text = "local main = true",
      encoding = "utf-8",
    }, context.stored_position)
    assert.same(original_window, deps.windows[deps.origin_win])
    assert.equals(original_current, state.flow.current_node_id)
    assert.equals(original_tracking, state.tracking_token)
    assert.equals(existing_claim, state.destination_claim)

    local method = Actions.get("incoming_calls").method
    local key = "relation:" .. root_id .. ":" .. method
    assert.equals("loading", state.relations[key].state)
    assert.equals(key, deps.sidebar.focus_relation_calls[1].key)
    assert.equals(1, state.request_count)

    deps.sidebar.selected_key_value = "location:unrelated"
    local focus_count = #deps.sidebar.focus_relation_calls
    deps.lsp:complete(1, outcome("incoming_calls", root_id, {}, { status = "empty" }))

    assert.equals(0, state.request_count)
    assert.is_nil(state.relations[key])
    assert.equals("location:unrelated", deps.sidebar:selected_key())
    assert.equals(focus_count, #deps.sidebar.focus_relation_calls)
    assert.same(original_window, deps.windows[deps.origin_win])
    assert.equals(original_current, state.flow.current_node_id)
    assert.equals(original_tracking, state.tracking_token)
    assert.equals(existing_claim, state.destination_claim)
    local action = assert(state.flow:action_for(root_id, method))
    assert.equals("complete", action.query_status)
    assert.same({}, state.flow:action_target_ids(action))
  end)

  it("queries from a persisted symbol anchor and rejects it after the source line changes", function()
    local session, deps = new_session()
    local state = session:state()
    local call_site = Fixtures.location("lua/calls.lua", 0, "caller")
    call_site.query_anchor = {
      locator = { kind = "project", path = "lua/caller.lua" },
      range = {
        start = { line = 0, character = 9 },
        ["end"] = { line = 0, character = 15 },
      },
      line_text = "function caller()",
    }
    local seed = state.flow:commit_navigation({
      origin_node_id = state.flow.root.id,
      method = "textDocument/definition",
      label = "definition",
      locations = { call_site },
    })
    local caller_id = seed.node_id_by_identity[call_site.identity]
    deps:add_buffer(71, "/project/lua/caller.lua", { lines = { "function caller()" } })
    deps.locator.open_target_result = { bufnr = 71, row = 1, col = 9 }

    session:show_callers(row(caller_id))

    assert.same({
      locator = call_site.query_anchor.locator,
      range = call_site.query_anchor.range,
    }, deps.locator.open_target_calls[1])
    assert.same({
      uri = "file:///project/lua/caller.lua",
      line = 0,
      character = 9,
      line_text = "function caller()",
      encoding = "utf-8",
    }, deps.lsp.starts[1].context.stored_position)
    local stored = state.flow:location(caller_id).location
    assert.same(call_site.locator, stored.locator)
    assert.same(call_site.range, stored.range)

    deps.lsp:complete(1, outcome("incoming_calls", caller_id, {}, { status = "empty" }))
    deps.buffers[71].lines[1] = "function moved()"
    assert.is_nil(session:show_callers(row(caller_id), true))
    assert.equals(1, #deps.lsp.starts)
    local method = Actions.get("incoming_calls").method
    local relation = state.relations["relation:" .. caller_id .. ":" .. method]
    assert.equals("error", relation.state)
    assert.equals("stored symbol query anchor changed", relation.message)
  end)

  it("queries an enriched reference from the symbol named by its row", function()
    local session, deps = new_session()
    local state = session:state()
    local reference = Fixtures.location("lua/service.lua", 0, "value")
    deps.lsp.auto_outcome = outcome("references", state.flow.root.id, { reference })
    session:run_action("references")
    deps.lsp.auto_outcome = nil

    local references = assert(state.flow:action_for(state.flow.root.id, "textDocument/references"))
    local reference_id = assert(state.flow:action_target_ids(references)[1])
    local display_range = vim.deepcopy(state.flow:location(reference_id).location.range)
    local anchor = {
      locator = { kind = "project", path = "lua/service.lua" },
      range = {
        start = { line = 0, character = 9 },
        ["end"] = { line = 0, character = 12 },
      },
      line_text = "function Bar()",
    }
    deps.symbols.on_done({
      [reference_id] = { symbol = "Bar", kind = "function", query_anchor = anchor },
    })

    local enriched = state.flow:location(reference_id).location
    assert.equals("Bar", enriched.symbol)
    assert.same(display_range, enriched.range)
    assert.same(anchor, enriched.query_anchor)

    deps:add_buffer(72, "/project/lua/service.lua", { lines = { "function Bar()" } })
    deps.locator.open_target_result = { bufnr = 72, row = 1, col = 9 }
    session:show_callees(row(reference_id))

    assert.same(
      { locator = anchor.locator, range = anchor.range },
      deps.locator.open_target_calls[#deps.locator.open_target_calls]
    )
    assert.same({
      uri = "file:///project/lua/service.lua",
      line = 0,
      character = 9,
      line_text = "function Bar()",
      encoding = "utf-8",
    }, deps.lsp.starts[2].context.stored_position)
  end)

  it("keeps a call-hierarchy name and anchor authoritative during enrichment", function()
    local session, deps = new_session()
    local state = session:state()
    local call_site = Fixtures.location("lua/call_site.lua", 4, "ProtocolCaller")
    call_site.symbol_kind = "function"
    local protocol_anchor = {
      locator = { kind = "project", path = "lua/caller.lua" },
      range = {
        start = { line = 1, character = 9 },
        ["end"] = { line = 1, character = 23 },
      },
      line_text = "function ProtocolCaller()",
    }
    call_site.query_anchor = protocol_anchor
    local commit = state.flow:commit_navigation({
      origin_node_id = state.flow.root.id,
      method = Actions.get("incoming_calls").method,
      label = "callers",
      locations = { call_site },
    })
    local caller_id = assert(commit.node_id_by_identity[call_site.identity])

    local resolve_count = #deps.symbols.resolve_calls
    session:_enrich_nodes(state, state.generation, state.flow.flow_id, { caller_id })
    assert.equals(resolve_count, #deps.symbols.resolve_calls)

    local stored = state.flow:location(caller_id).location
    assert.equals("ProtocolCaller", stored.symbol)
    assert.same(protocol_anchor, stored.query_anchor)
    assert.equals("function", stored.symbol_kind)
  end)

  it("keeps an in-flight directional query aligned when enrichment settles late", function()
    local session, deps = new_session()
    local state = session:state()
    local reference = Fixtures.location("lua/service.lua", 0, "value")
    deps.lsp.auto_outcome = outcome("references", state.flow.root.id, { reference })
    session:run_action("references")
    deps.lsp.auto_outcome = nil

    local references = assert(state.flow:action_for(state.flow.root.id, "textDocument/references"))
    local reference_id = assert(state.flow:action_target_ids(references)[1])
    local enrichment_done = assert(deps.symbols.on_done)
    session:show_callers(row(reference_id))
    local renders = deps.sidebar.render_count

    enrichment_done({
      [reference_id] = {
        symbol = "Bar",
        kind = "function",
        query_anchor = {
          locator = { kind = "project", path = "lua/service.lua" },
          range = {
            start = { line = 0, character = 9 },
            ["end"] = { line = 0, character = 12 },
          },
          line_text = "function Bar()",
        },
      },
    })

    local stored = state.flow:location(reference_id).location
    assert.equals("value", stored.symbol)
    assert.is_nil(stored.query_anchor)
    assert.equals(renders, deps.sidebar.render_count)
    assert.equals(1, state.request_count)
    assert.same({}, deps.lsp.handles[2].cancel_calls)

    deps.lsp:complete(2, outcome("incoming_calls", reference_id, {}, { status = "empty" }))
    assert.is_table(state.flow:action_for(reference_id, Actions.get("incoming_calls").method))
    assert.equals(0, state.request_count)
    enrichment_done({
      [reference_id] = {
        symbol = "Bar",
        kind = "function",
        query_anchor = {
          locator = { kind = "project", path = "lua/service.lua" },
          range = {
            start = { line = 0, character = 9 },
            ["end"] = { line = 0, character = 12 },
          },
          line_text = "function Bar()",
        },
      },
    })
    assert.equals("value", state.flow:location(reference_id).location.symbol)
  end)

  it("expands and focuses a cached relation without dispatching LSP", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local method = Actions.get("outgoing_calls").method
    local commit = state.flow:commit_navigation({
      origin_node_id = root_id,
      method = method,
      label = "calls",
      locations = {},
      query_status = "complete",
    })
    assert.is_true(state.flow:set_collapsed(commit.action_id, true))

    assert.is_true(session:show_callees(row(root_id)))

    assert.equals(0, #deps.lsp.starts)
    assert.is_false(state.flow:find(commit.action_id).collapsed)
    assert.same({
      origin_id = root_id,
      method = method,
      key = "relation:" .. root_id .. ":" .. method,
    }, deps.sidebar.focus_relation_calls[#deps.sidebar.focus_relation_calls])
  end)

  it("coalesces an in-flight relation and retries a failed one", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local method = Actions.get("incoming_calls").method
    local key = "relation:" .. root_id .. ":" .. method

    session:show_callers(row(root_id))
    session:show_callers({ kind = "relation", context_location_id = root_id })
    assert.equals(1, #deps.lsp.starts)
    assert.equals(2, #deps.sidebar.focus_relation_calls)
    assert.equals(1, state.request_count)

    deps.lsp:complete(
      1,
      outcome("incoming_calls", root_id, {}, {
        status = "error",
        failures = { { kind = "protocol", message = "server failed" } },
      })
    )
    assert.equals(0, state.request_count)
    assert.equals("error", state.relations[key].state)
    assert.equals("server failed", state.relations[key].message)

    session:show_callers(row(root_id))
    assert.equals(2, #deps.lsp.starts)
    assert.equals("loading", state.relations[key].state)
    assert.equals(1, state.request_count)
  end)

  it("turns stored-source resolution failures into retryable relation errors", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    deps.locator.open_target = function()
      error("buffer load exploded")
    end

    assert.has_no.errors(function()
      assert.is_nil(session:show_callers(row(root_id)))
    end)

    local method = Actions.get("incoming_calls").method
    local key = "relation:" .. root_id .. ":" .. method
    assert.equals(0, state.request_count)
    assert.is_nil(state.relation_requests[key])
    assert.equals("error", state.relations[key].state)
    assert.matches("buffer load exploded", state.relations[key].message, nil, true)
    assert.equals(0, #deps.lsp.starts)
  end)

  it("retains cached data and replacement intent when a refresh fails", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local action_record = Actions.get("incoming_calls")
    local existing = Fixtures.location("lua/existing.lua", 0, "existing")
    local commit = state.flow:commit_navigation({
      origin_node_id = root_id,
      method = action_record.method,
      label = action_record.label,
      locations = { existing },
      query_status = "complete",
    })
    local previous_targets = state.flow:action_target_ids(commit.action_id)
    assert.is_true(state.flow:set_collapsed(commit.action_id, true))

    session:show_callers(row(root_id), true)
    assert.equals(1, #deps.lsp.starts)
    assert.is_false(state.flow:find(commit.action_id).collapsed)
    session:show_callers(row(root_id))
    assert.equals(1, #deps.lsp.starts)
    deps.lsp:complete(
      1,
      outcome("incoming_calls", root_id, {}, {
        status = "timeout",
        failures = { { kind = "timeout", message = "late" } },
      })
    )

    local cached = assert(state.flow:action_for(root_id, action_record.method))
    assert.same(previous_targets, state.flow:action_target_ids(cached))
    local key = "relation:" .. root_id .. ":" .. action_record.method
    assert.equals("error", state.relations[key].state)
    assert.is_true(state.relations[key].replace_targets)

    session:show_callers(row(root_id))
    assert.equals(2, #deps.lsp.starts)
    assert.equals("loading", state.relations[key].state)
    assert.is_true(deps.lsp.starts[2].context.replace_targets)
    deps.lsp:complete(2, outcome("incoming_calls", root_id, {}, { status = "empty" }))
    assert.same({}, state.flow:action_target_ids(cached))
    assert.is_nil(state.relations[key])
  end)

  it("upgrades a coalesced lowercase retry when an explicit refresh arrives", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local record = Actions.get("incoming_calls")
    local key = "relation:" .. root_id .. ":" .. record.method

    session:show_callers(row(root_id))
    deps.lsp:complete(
      1,
      outcome("incoming_calls", root_id, {}, {
        status = "error",
        failures = { { kind = "protocol", message = "first attempt failed" } },
      })
    )
    assert.is_false(state.relations[key].replace_targets)

    local existing = Fixtures.location("lua/existing.lua", 0, "existing")
    session:run_action("incoming_calls")
    deps.lsp:complete(2, outcome("incoming_calls", root_id, { existing }))
    local cached = assert(state.flow:action_for(root_id, record.method))
    assert.equals(1, #state.flow:action_target_ids(cached))

    session:show_callers(row(root_id))
    assert.is_false(deps.lsp.starts[3].context.replace_targets)
    assert.is_false(state.relation_requests[key].replace_targets)
    session:show_callers(row(root_id), true)

    assert.equals(3, #deps.lsp.starts)
    assert.is_true(state.relation_requests[key].replace_targets)
    assert.is_true(state.relations[key].replace_targets)
    deps.lsp:complete(3, outcome("incoming_calls", root_id, {}, { status = "empty" }))
    assert.same({}, state.flow:action_target_ids(cached))
    assert.is_nil(state.relations[key])
  end)

  it("restarts an upgraded lowercase request when its relation changed in flight", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local record = Actions.get("incoming_calls")
    local newer = Fixtures.location("lua/newer.lua", 0, "newer")
    local stale = Fixtures.location("lua/stale.lua", 0, "stale")

    session:show_callers(row(root_id))
    session:run_action("incoming_calls")
    deps.lsp:complete(2, outcome("incoming_calls", root_id, { newer }))
    local action = assert(state.flow:action_for(root_id, record.method))
    local newer_id = assert(state.flow:action_target_ids(action)[1])

    session:show_callers(row(root_id), true)
    assert.equals(3, #deps.lsp.starts)
    assert.same({ "refresh" }, deps.lsp.handles[1].cancel_calls)
    assert.is_true(deps.lsp.starts[3].context.replace_targets)
    assert.equals(1, state.request_count)

    deps.lsp:complete(1, outcome("incoming_calls", root_id, { stale }))
    assert.same({ newer_id }, state.flow:action_target_ids(action))
    deps.lsp:complete(3, outcome("incoming_calls", root_id, {}, { status = "empty" }))
    assert.same({}, state.flow:action_target_ids(action))
    assert.equals(0, state.request_count)
  end)

  it("discards a stale refresh after a newer ordinary commit wins", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local record = Actions.get("incoming_calls")
    local newer = Fixtures.location("lua/newer.lua", 0, "newer")
    local stale = Fixtures.location("lua/stale.lua", 0, "stale")

    session:show_callers(row(root_id), true)
    session:run_action("incoming_calls")
    deps.lsp:complete(2, outcome("incoming_calls", root_id, { newer }))

    local action = assert(state.flow:action_for(root_id, record.method))
    local newer_id = assert(state.flow:action_target_ids(action)[1])
    assert.equals(newer.identity, Locator.location_key(state.flow:location(newer_id).location))
    deps.lsp:complete(1, outcome("incoming_calls", root_id, { stale }))

    assert.same({ newer_id }, state.flow:action_target_ids(action))
    assert.equals(2, #vim.tbl_filter(function(node)
      return node.kind == "location"
    end, state.flow:dfs()))
    assert.equals(0, state.request_count)
    assert.is_nil(state.relations["relation:" .. root_id .. ":" .. record.method])
  end)

  it("cancels a deleted relation without disturbing another directional request", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local incoming = Actions.get("incoming_calls")
    local outgoing = Actions.get("outgoing_calls")
    local existing = Fixtures.location("lua/existing.lua", 0, "existing")
    local seed = state.flow:commit_navigation({
      origin_node_id = root_id,
      method = incoming.method,
      label = incoming.label,
      locations = { existing },
    })
    local existing_id = seed.node_id_by_identity[existing.identity]

    session:show_callers(row(root_id), true)
    session:show_callees(row(root_id))
    assert.equals(2, state.request_count)
    assert.is_true(session:delete_row({ kind = "action", owner_id = seed.action_id }))

    local incoming_key = "relation:" .. root_id .. ":" .. incoming.method
    local outgoing_key = "relation:" .. root_id .. ":" .. outgoing.method
    assert.same({ "delete" }, deps.lsp.handles[1].cancel_calls)
    assert.same({}, deps.lsp.handles[2].cancel_calls)
    assert.is_nil(state.relation_requests[incoming_key])
    assert.is_nil(state.relations[incoming_key])
    assert.is_table(state.relation_requests[outgoing_key])
    assert.equals("loading", state.relations[outgoing_key].state)
    assert.equals(1, state.request_count)
    assert.is_nil(state.flow:action_for(root_id, incoming.method))
    assert.is_table(state.flow:location(existing_id))

    deps.lsp:complete(1, outcome("incoming_calls", root_id, { existing }))
    assert.is_nil(state.flow:action_for(root_id, incoming.method))
    assert.equals(1, state.request_count)

    local callee = Fixtures.location("lua/callee.lua", 0, "callee")
    deps.lsp:complete(2, outcome("outgoing_calls", root_id, { callee }))
    assert.is_table(state.flow:action_for(root_id, outgoing.method))
    assert.equals(0, state.request_count)
  end)

  it("cancels matching ordinary call requests when their relation is deleted", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local incoming = Actions.get("incoming_calls")
    local outgoing = Actions.get("outgoing_calls")
    local existing = Fixtures.location("lua/existing.lua", 0, "existing")
    local seed = state.flow:commit_navigation({
      origin_node_id = root_id,
      method = incoming.method,
      label = incoming.label,
      locations = { existing },
    })

    session:run_action("incoming_calls")
    session:run_action("outgoing_calls")
    assert.equals(2, state.request_count)
    assert.is_true(session:delete_row({ kind = "action", owner_id = seed.action_id }))

    local incoming_key = "relation:" .. root_id .. ":" .. incoming.method
    local outgoing_key = "relation:" .. root_id .. ":" .. outgoing.method
    assert.same({ "delete" }, deps.lsp.handles[1].cancel_calls)
    assert.same({}, deps.lsp.handles[2].cancel_calls)
    assert.is_nil(state.ordinary_relation_requests[incoming_key])
    assert.is_table(state.ordinary_relation_requests[outgoing_key])
    assert.equals(1, state.request_count)
    assert.is_nil(state.flow:action_for(root_id, incoming.method))

    local late = Fixtures.location("lua/late.lua", 0, "late")
    deps.lsp:complete(1, outcome("incoming_calls", root_id, { late }))
    assert.is_nil(state.flow:action_for(root_id, incoming.method))
    assert.equals(1, state.request_count)

    local callee = Fixtures.location("lua/callee.lua", 0, "callee")
    deps.lsp:complete(2, outcome("outgoing_calls", root_id, { callee }))
    assert.is_table(state.flow:action_for(root_id, outgoing.method))
    assert.equals(0, state.request_count)
  end)

  it("keeps an unlinked occurrence removed after a late ordinary call result", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local incoming = Actions.get("incoming_calls")
    local existing = Fixtures.location("lua/existing.lua", 0, "existing")
    local seed = state.flow:commit_navigation({
      origin_node_id = root_id,
      method = incoming.method,
      label = incoming.label,
      locations = { existing },
    })
    local existing_id = assert(seed.node_id_by_identity[existing.identity])

    session:run_action("incoming_calls")
    assert.is_true(session:delete_row({
      kind = "location",
      owner_id = existing_id,
      context_location_id = existing_id,
      action_id = seed.action_id,
    }))

    local action = assert(state.flow:action_for(root_id, incoming.method))
    assert.same({}, state.flow:action_target_ids(action))
    assert.same({ "delete" }, deps.lsp.handles[1].cancel_calls)
    assert.equals(0, state.request_count)

    deps.lsp:complete(1, outcome("incoming_calls", root_id, { existing }))
    assert.same({}, state.flow:action_target_ids(action))
    assert.is_table(state.flow:location(existing_id))
    assert.equals(0, state.request_count)
  end)

  it("does not supersede unrelated directional requests", function()
    local session, deps = new_session()
    local root_id = session:state().flow.root.id

    session:show_callers(row(root_id))
    session:run_action("definition")

    assert.equals(2, #deps.lsp.starts)
    assert.equals(0, deps.lsp.handles[1].supersede_calls)
    assert.equals(0, deps.lsp.handles[2].supersede_calls)
    assert.equals(2, session:state().request_count)
  end)

  it("merges a partial refresh instead of replacing the prior cache", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local record = Actions.get("outgoing_calls")
    local existing = Fixtures.location("lua/existing.lua", 0, "existing")
    local fresh = Fixtures.location("lua/fresh.lua", 0, "fresh")
    local seed = state.flow:commit_navigation({
      origin_node_id = root_id,
      method = record.method,
      label = record.label,
      locations = { existing },
      query_status = "complete",
    })
    local existing_id = seed.node_id_by_identity[existing.identity]

    session:show_callees(row(root_id), true)
    deps.lsp:complete(
      1,
      outcome("outgoing_calls", root_id, { fresh }, {
        status = "partial",
        failures = { { kind = "protocol", message = "one client failed" } },
      })
    )

    local action = assert(state.flow:action_for(root_id, record.method))
    local targets = state.flow:action_target_ids(action)
    assert.equals(2, #targets)
    assert.equals(existing_id, targets[1])
    assert.equals(fresh.identity, Locator.location_key(state.flow:location(targets[2]).location))
    assert.equals("partial", action.query_status)
  end)

  it("records an edge when a directional result already exists elsewhere", function()
    local session, deps = new_session()
    local state = session:state()
    local root_id = state.flow.root.id
    local existing = Fixtures.location("lua/shared.lua", 0, "shared")
    local seed = state.flow:commit_navigation({
      origin_node_id = root_id,
      method = "textDocument/definition",
      label = "definition",
      locations = { existing },
      query_status = "complete",
    })
    local existing_id = seed.node_id_by_identity[existing.identity]

    session:show_callers(row(root_id))
    deps.lsp:complete(1, outcome("incoming_calls", root_id, { existing }))

    local method = Actions.get("incoming_calls").method
    local relation = assert(state.flow:action_for(root_id, method))
    assert.same({ existing_id }, state.flow:action_target_ids(relation))
    assert.equals("complete", relation.query_status)
  end)
end)
