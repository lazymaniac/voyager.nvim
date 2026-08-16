local Actions = require("voyager.lsp.actions")
local CallHierarchy = require("voyager.lsp.call_hierarchy")
local FakeClient = require("tests.helpers.fake_lsp_client")
local FakeTimer = require("tests.helpers.fake_timer")
local RequestGroup = require("voyager.lsp.request_group")

local function prepared(name, uri)
  return {
    name = name,
    kind = 12,
    uri = uri or ("file:///project/" .. name .. ".lua"),
    range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = #name } },
    selectionRange = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = #name } },
  }
end

local function new_harness(opts)
  opts = opts or {}
  local timers = FakeTimer.new()
  local select_calls = {}
  local completions = {}
  local normalization_calls = {}
  local ownership_checks = {}
  local owns = opts.owns ~= false
  local clients = vim.tbl_map(function(client)
    return client:snapshot()
  end, opts.clients or {})
  local action = Actions.get(opts.action or "incoming_calls")
  local normalizer = {
    is_project_uri = function(_, uri)
      if opts.is_project_uri then
        return opts.is_project_uri(uri)
      end
      return type(uri) == "string" and uri:sub(1, 16) == "file:///project/"
    end,
    call_sites = function(_, direction, client, selected, calls)
      table.insert(normalization_calls, {
        direction = direction,
        client = client,
        selected = selected,
        calls = vim.deepcopy(calls),
      })
      if calls == nil or #calls == 0 then
        return {}, {}, {}, {
          usable_response_count = 1,
          empty_response_count = 1,
          invalid_response_count = 0,
        }
      end
      return { { identity = "site", raw = vim.deepcopy(calls[1]) } }, { { identity = "site" } }, {}, {
        usable_response_count = 1,
        empty_response_count = 0,
        invalid_response_count = 0,
      }
    end,
  }

  local handle = CallHierarchy.start({
    action = action,
    context = {
      generation = 4,
      request_token = 12,
      origin_node_id = "loc-root",
      bufnr = 3,
      winid = 8,
      timeout_ms = 1000,
      automatic = opts.automatic == true,
    },
    clients = clients,
    request_stage = RequestGroup.start,
    normalizer = normalizer,
    timer = timers.factory,
    make_position_params = function(winid, encoding)
      return { winid = winid, encoding = encoding }
    end,
    select = function(items, select_opts, callback)
      if opts.select_then_error then
        callback(items[1])
        error(opts.select_then_error)
      end
      if opts.select_error then
        error(opts.select_error)
      end
      table.insert(select_calls, {
        items = items,
        opts = select_opts,
        callback = callback,
      })
    end,
    owns_presentation = function(token)
      table.insert(ownership_checks, token)
      return owns
    end,
    on_complete = function(outcome)
      table.insert(completions, outcome)
    end,
  })

  return {
    action = action,
    handle = handle,
    timers = timers,
    select_calls = select_calls,
    completions = completions,
    normalization_calls = normalization_calls,
    ownership_checks = ownership_checks,
    set_owns = function(value)
      owns = value
    end,
  }
end

describe("Voyager call hierarchy", function()
  it("retains the prepared tuple and follows up only on its originating client", function()
    local client_a = FakeClient.new({ id = 1, name = "alpha", offset_encoding = "utf-16" })
    local client_b = FakeClient.new({ id = 2, name = "zeta", offset_encoding = "utf-8" })
    local env = new_harness({ clients = { client_b, client_a } })
    local prepared_a = prepared("prepared_a")

    assert.same({ "textDocument/prepareCallHierarchy" }, client_a.methods)
    assert.same({ "textDocument/prepareCallHierarchy" }, client_b.methods)
    client_a:reply_prepare(nil, { prepared_a })
    client_b:reply_prepare(nil, {})

    assert.same({ "textDocument/prepareCallHierarchy", "callHierarchy/incomingCalls" }, client_a.methods)
    assert.same({ "textDocument/prepareCallHierarchy" }, client_b.methods)
    assert.same({ method = "callHierarchy/incomingCalls", bufnr = 3 }, client_a.supports_calls[1])
    assert.equals(2, #env.timers.created)
    assert.same(
      { 1000, 1000 },
      vim.tbl_map(function(timer)
        return timer.timeout_ms
      end, env.timers.created)
    )

    client_a:reply_followup(nil, { { from = prepared("caller"), fromRanges = { prepared_a.selectionRange } } })
    assert.equals(1, #env.completions)
    assert.equals("success", env.completions[1].status)
    assert.equals("incoming", env.normalization_calls[1].direction)
    assert.equals(1, env.normalization_calls[1].selected.client_id)
    assert.equals(1, env.normalization_calls[1].selected.response_index)
    assert.same(prepared_a, env.normalization_calls[1].selected.item)
  end)

  it("routes outgoing calls through the selected client", function()
    local client = FakeClient.new({ id = 3, name = "only" })
    local env = new_harness({ clients = { client }, action = "outgoing_calls" })
    client:reply_prepare(nil, { prepared("origin") })
    assert.same({ "textDocument/prepareCallHierarchy", "callHierarchy/outgoingCalls" }, client.methods)
    client:reply_followup(nil, {})
    assert.equals("empty", env.completions[1].status)
    assert.equals("outgoing", env.normalization_calls[1].direction)
  end)

  it("skips external prepared items and follows the sole project item", function()
    local client = FakeClient.new({ id = 3, name = "only" })
    local env = new_harness({ clients = { client }, action = "outgoing_calls" })
    local internal = prepared("origin")
    local external = prepared("vendor", "file:///vendor/vendor.lua")

    client:reply_prepare(nil, { external, internal })

    assert.equals(0, #env.select_calls)
    assert.same(internal, client.requests[2].params.item)
    client:reply_followup(nil, {})
    assert.equals("empty", env.completions[1].status)
  end)

  it("classifies all-external prepared items as an empty hierarchy", function()
    local client = FakeClient.new({ id = 3, name = "only" })
    local env = new_harness({ clients = { client } })

    client:reply_prepare(nil, {
      prepared("vendor", "file:///vendor/vendor.lua"),
      prepared("class", "jdt://contents/Vendor.class"),
    })

    assert.equals(1, #client.methods)
    assert.equals(0, #env.select_calls)
    assert.equals(1, #env.completions)
    assert.equals("empty", env.completions[1].status)
    assert.same({}, env.completions[1].failures)
  end)

  it("opens a timer-free picker for multiple immutable prepared tuples", function()
    local client = FakeClient.new({ id = 1, name = "alpha" })
    local env = new_harness({ clients = { client } })
    local first = prepared("first")
    local second = prepared("second")
    client:reply_prepare(nil, { first, second })

    assert.equals(1, #env.select_calls)
    assert.equals(1, #env.timers.created)
    assert.equals(1, env.timers.created[1].close_count)
    assert.same(
      { 1, 2 },
      vim.tbl_map(function(item)
        return item.response_index
      end, env.select_calls[1].items)
    )
    assert.same(
      { 1, 1 },
      vim.tbl_map(function(item)
        return item.client_id
      end, env.select_calls[1].items)
    )

    first.name = "mutated"
    env.select_calls[1].callback(env.select_calls[1].items[2])
    assert.equals(2, #env.timers.created)
    assert.equals(1000, env.timers.created[2].timeout_ms)
    assert.same(second, client.requests[2].params.item)
    client:reply_followup(nil, {})
    assert.equals("empty", env.completions[1].status)
  end)

  it("uses the first project item without prompting during automatic creation", function()
    local client = FakeClient.new({ id = 1, name = "alpha" })
    local env = new_harness({ clients = { client }, automatic = true })
    local first = prepared("first")
    local second = prepared("second")
    client:reply_prepare(nil, { first, second })

    assert.equals(0, #env.select_calls)
    assert.same(first, client.requests[2].params.item)
    client:reply_followup(nil, {})
    assert.equals("empty", env.completions[1].status)
  end)

  it("rejects malformed prepared items without opening or leaking a picker", function()
    local client = FakeClient.new({ id = 1, name = "alpha" })
    local env = new_harness({ clients = { client } })

    client:reply_prepare(nil, { 42, { name = "missing URI" } })

    assert.equals(0, #env.select_calls)
    assert.equals(1, #env.completions)
    assert.equals("error", env.completions[1].status)
    assert.same(
      { "normalization", "normalization" },
      vim.tbl_map(function(failure)
        return failure.kind
      end, env.completions[1].failures)
    )
    assert.is_true(env.handle:is_done())
    assert.equals(1, env.timers.created[1].close_count)
  end)

  it("keeps valid prepared items and reports malformed siblings as partial", function()
    local client = FakeClient.new({ id = 1, name = "alpha" })
    local env = new_harness({ clients = { client } })
    local valid = prepared("valid")

    client:reply_prepare(nil, { valid, false })
    assert.same({ "textDocument/prepareCallHierarchy", "callHierarchy/incomingCalls" }, client.methods)
    client:reply_followup(nil, {})

    assert.equals("partial", env.completions[1].status)
    assert.equals("normalization", env.completions[1].failures[1].kind)
  end)

  it("settles when the call-hierarchy picker provider throws", function()
    local client = FakeClient.new({ id = 1, name = "alpha" })
    local env = new_harness({ clients = { client }, select_error = "picker exploded" })

    assert.has_no.errors(function()
      client:reply_prepare(nil, { prepared("first"), prepared("second") })
    end)

    assert.equals(1, #env.completions)
    assert.equals("error", env.completions[1].status)
    assert.equals("ui", env.completions[1].failures[1].kind)
    assert.is_true(env.handle:is_done())
  end)

  it("cancels a follow-up started by a picker that then throws", function()
    local client = FakeClient.new({ id = 1, name = "alpha" })
    local env = new_harness({ clients = { client }, select_then_error = "picker exploded late" })

    client:reply_prepare(nil, { prepared("first"), prepared("second") })

    assert.equals(1, #env.completions)
    assert.equals("error", env.completions[1].status)
    assert.equals("ui", env.completions[1].failures[1].kind)
    assert.same({ client.request_id }, client.cancelled)
    assert.equals(1, env.timers.created[2].close_count)
    client:reply_followup(nil, {})
    assert.equals(1, #env.completions)
  end)

  it("treats picker cancellation as one logical cancellation", function()
    local client = FakeClient.new({ id = 1, name = "alpha" })
    local env = new_harness({ clients = { client } })
    client:reply_prepare(nil, { prepared("first"), prepared("second") })
    env.select_calls[1].callback(nil)
    assert.equals(1, #env.completions)
    assert.equals("cancelled", env.completions[1].status)
    assert.equals(1, #client.methods)
  end)

  it("distinguishes empty, partial-empty, prepare unsupported, and follow-up unsupported", function()
    local empty_client = FakeClient.new({ id = 1, name = "empty" })
    local empty = new_harness({ clients = { empty_client } })
    empty_client:reply_prepare(nil, {})
    assert.equals("empty", empty.completions[1].status)

    local failing = FakeClient.new({ id = 1, name = "alpha" })
    local usable = FakeClient.new({ id = 2, name = "zeta" })
    local partial = new_harness({ clients = { failing, usable } })
    failing:reply_prepare({ message = "prepare failed" }, nil)
    usable:reply_prepare(nil, {})
    assert.equals("partial", partial.completions[1].status)
    assert.equals("protocol", partial.completions[1].failures[1].kind)

    local unsupported = new_harness({ clients = {} })
    assert.equals("unsupported", unsupported.completions[1].status)
    assert.equals(0, #unsupported.timers.created)

    local no_follow = FakeClient.new({ id = 3, name = "no-follow", supports = false })
    local follow = new_harness({ clients = { no_follow } })
    no_follow:reply_prepare(nil, { prepared("only") })
    assert.equals("unsupported", follow.completions[1].status)
    assert.equals(1, #follow.timers.created)
    assert.equals(1, #no_follow.methods)
  end)

  it("lets a single result continue after ownership is lost", function()
    local client = FakeClient.new({ id = 1, name = "alpha" })
    local env = new_harness({ clients = { client } })
    env.set_owns(false)
    client:reply_prepare(nil, { prepared("only") })
    assert.equals("callHierarchy/incomingCalls", client.methods[2])
    assert.equals(0, #env.select_calls)
    client:reply_followup(nil, {})
    assert.equals("empty", env.completions[1].status)
  end)

  it("supersedes a required or open multi-result picker safely", function()
    local client = FakeClient.new({ id = 1, name = "alpha" })
    local lost = new_harness({ clients = { client }, owns = false })
    client:reply_prepare(nil, { prepared("first"), prepared("second") })
    assert.equals("superseded", lost.completions[1].status)
    assert.equals(0, #lost.select_calls)

    client = FakeClient.new({ id = 1, name = "alpha" })
    local open = new_harness({ clients = { client } })
    client:reply_prepare(nil, { prepared("first"), prepared("second") })
    local stale_callback = open.select_calls[1].callback
    local stale_item = open.select_calls[1].items[1]
    open.handle:supersede_interactive()
    assert.equals("superseded", open.completions[1].status)
    stale_callback(stale_item)
    assert.equals(1, #open.completions)
    assert.equals(1, #client.methods)
    for _, token in ipairs(open.ownership_checks) do
      assert.equals(12, token)
    end
    for _, token in ipairs(lost.ownership_checks) do
      assert.equals(12, token)
    end
  end)

  it("cancels a pending network stage exactly once", function()
    local client = FakeClient.new({ id = 1, name = "alpha" })
    local env = new_harness({ clients = { client } })
    env.handle:cancel("close")
    assert.equals("cancelled", env.completions[1].status)
    assert.same({ client.request_id }, client.cancelled)
    client:reply_prepare(nil, { prepared("late") })
    assert.equals(1, #env.completions)
  end)
end)
