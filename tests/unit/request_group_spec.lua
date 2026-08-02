local FakeClient = require("tests.helpers.fake_lsp_client")
local FakeTimer = require("tests.helpers.fake_timer")
local RequestGroup = require("voyager.lsp.request_group")

local function snapshot(spec)
  return FakeClient.new(spec):snapshot()
end

local function failure_kinds(outcome)
  return vim.tbl_map(function(item)
    return item.kind
  end, outcome.failures)
end

local function start(clients, overrides)
  local timers = FakeTimer.new()
  local completions = {}
  overrides = overrides or {}
  local handle = RequestGroup.start({
    clients = clients,
    method = "textDocument/definition",
    bufnr = 3,
    timeout_ms = 1000,
    make_params = overrides.make_params or function(client)
      return { client = client.id }
    end,
    timer = timers.factory,
    on_complete = function(outcome)
      table.insert(completions, outcome)
    end,
  })
  return handle, timers, completions
end

local function assert_timer_closed_once(timers)
  assert.equals(1, #timers.created)
  assert.equals(1, timers.last.cancel_count)
  assert.equals(1, timers.last.close_count)
end

describe("Voyager LSP request groups", function()
  it("holds synchronous callbacks behind the dispatch barrier", function()
    local sync = snapshot({
      id = 1,
      name = "alpha",
      sync_reply = { result = { "sync" } },
    })
    local async = snapshot({ id = 2, name = "zeta" })
    local handle, timers, completions = start({ async, sync })

    assert.equals(0, #completions)
    async.client:reply(nil, {})
    assert.equals(1, #completions)
    assert.is_true(handle:is_done())
    sync.client:reply_late(nil, {})
    assert.equals(1, #completions)
    assert.same(
      { "alpha", "zeta" },
      vim.tbl_map(function(response)
        return response.client.name
      end, completions[1].responses)
    )
    assert.same({}, completions[1].failures)
    assert.equals("success", completions[1].status)
    assert.same({}, sync.client.cancelled)
    assert_timer_closed_once(timers)
  end)

  it("sorts out-of-order successful replies by client name and ID", function()
    local zeta = snapshot({ id = 9, name = "zeta" })
    local alpha_high = snapshot({ id = 8, name = "alpha" })
    local alpha_low = snapshot({ id = 2, name = "alpha" })
    local handle, timers, completions = start({ zeta, alpha_high, alpha_low })

    zeta.client:reply(nil, { 9 })
    alpha_high.client:reply(nil, { 8 })
    assert.is_false(handle:is_done())
    alpha_low.client:reply(nil, { 2 })

    assert.equals("success", completions[1].status)
    assert.same(
      { 2, 8, 9 },
      vim.tbl_map(function(response)
        return response.client.id
      end, completions[1].responses)
    )
    assert_timer_closed_once(timers)
  end)

  it("turns both rejected dispatch return shapes into setup failures", function()
    for _, spec in ipairs({
      { id = 1, name = "false", accepted = false },
      { id = 2, name = "missing", missing_request_id = true },
    }) do
      local item = snapshot(spec)
      local handle, timers, completions = start({ item })

      assert.is_true(handle:is_done())
      assert.equals(1, #completions)
      assert.equals("error", completions[1].status)
      assert.same({}, completions[1].responses)
      assert.same({ "setup" }, failure_kinds(completions[1]))
      assert.equals("client rejected request", completions[1].failures[1].message)
      assert.same({}, item.client.cancelled)
      assert_timer_closed_once(timers)
    end
  end)

  it("classifies protocol-only and mixed protocol outcomes", function()
    local first = snapshot({ id = 1, name = "alpha" })
    local second = snapshot({ id = 2, name = "zeta" })
    local _, timers, completions = start({ first, second })
    second.client:reply({ message = "zeta failed" }, nil)
    first.client:reply({ message = "alpha failed" }, nil)

    assert.equals("error", completions[1].status)
    assert.same({ "protocol", "protocol" }, failure_kinds(completions[1]))
    assert.same(
      { "alpha failed", "zeta failed" },
      vim.tbl_map(function(item)
        return item.message
      end, completions[1].failures)
    )
    assert_timer_closed_once(timers)

    first = snapshot({ id = 1, name = "alpha" })
    second = snapshot({ id = 2, name = "zeta" })
    local _, mixed_timers, mixed = start({ first, second })
    second.client:reply({ message = "broken" }, nil)
    first.client:reply(nil, {})
    assert.equals("partial", mixed[1].status)
    assert.equals(1, #mixed[1].responses)
    assert.same({ "protocol" }, failure_kinds(mixed[1]))
    assert_timer_closed_once(mixed_timers)
  end)

  it("times out pending requests and preserves successful responses", function()
    local success = snapshot({ id = 1, name = "alpha" })
    local hung = snapshot({ id = 2, name = "zeta" })
    local handle, timers, completions = start({ success, hung })
    success.client:reply(nil, {})
    timers:fire()

    assert.is_true(handle:is_done())
    assert.equals("partial", completions[1].status)
    assert.equals(1, #completions[1].responses)
    assert.same({ "timeout" }, failure_kinds(completions[1]))
    assert.same({ hung.client.request_id }, hung.client.cancelled)
    hung.client:reply_late(nil, {})
    assert.equals(1, #completions)
    assert_timer_closed_once(timers)
  end)

  it("uses timeout only for exclusively timed-out total failures", function()
    local alpha = snapshot({ id = 1, name = "alpha" })
    local zeta = snapshot({ id = 2, name = "zeta" })
    local _, timers, completions = start({ zeta, alpha })
    timers:fire()

    assert.equals("timeout", completions[1].status)
    assert.same({ "timeout", "timeout" }, failure_kinds(completions[1]))
    assert.same({ alpha.client.request_id }, alpha.client.cancelled)
    assert.same({ zeta.client.request_id }, zeta.client.cancelled)
    assert_timer_closed_once(timers)

    local rejected = snapshot({ id = 1, name = "alpha", accepted = false })
    local hung = snapshot({ id = 2, name = "zeta" })
    local _, mixed_timers, mixed = start({ rejected, hung })
    mixed_timers:fire()
    assert.equals("error", mixed[1].status)
    assert.same({ "setup", "timeout" }, failure_kinds(mixed[1]))
    assert_timer_closed_once(mixed_timers)
  end)

  it("cancels all pending slots exactly once", function()
    local alpha = snapshot({ id = 1, name = "alpha" })
    local zeta = snapshot({ id = 2, name = "zeta" })
    local handle, timers, completions = start({ alpha, zeta })
    handle:cancel("close")

    assert.is_true(handle:is_done())
    assert.equals("cancelled", completions[1].status)
    assert.same({ "cancelled", "cancelled" }, failure_kinds(completions[1]))
    assert.same(
      { "close", "close" },
      vim.tbl_map(function(item)
        return item.message
      end, completions[1].failures)
    )
    assert.same({ alpha.client.request_id }, alpha.client.cancelled)
    assert.same({ zeta.client.request_id }, zeta.client.cancelled)
    alpha.client:reply_late(nil, {})
    handle:cancel("again")
    assert.equals(1, #completions)
    assert_timer_closed_once(timers)
  end)

  it("captures thrown setup work and never retains a synchronously settled request ID", function()
    local params_client = snapshot({ id = 1, name = "params" })
    local _, params_timer, params_done = start({ params_client }, {
      make_params = function()
        error("params exploded")
      end,
    })
    assert.equals("error", params_done[1].status)
    assert.same({ "setup" }, failure_kinds(params_done[1]))
    assert.matches("params exploded", params_done[1].failures[1].message, nil, true)
    assert.same({}, params_client.client.cancelled)
    assert_timer_closed_once(params_timer)

    local request_client = snapshot({ id = 2, name = "request", request_error = "request exploded" })
    local _, request_timer, request_done = start({ request_client })
    assert.matches("request exploded", request_done[1].failures[1].message, nil, true)
    assert.same({}, request_client.client.cancelled)
    assert_timer_closed_once(request_timer)

    local sync = snapshot({ id = 3, name = "sync", sync_reply = { result = {} } })
    local handle, sync_timer, sync_done = start({ sync })
    assert.is_true(handle:is_done())
    handle:cancel("late")
    assert.same({}, sync.client.cancelled)
    assert.equals(1, #sync_done)
    assert_timer_closed_once(sync_timer)
  end)
end)
