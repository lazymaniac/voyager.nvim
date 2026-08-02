local Actions = require("voyager.lsp.actions")
local FakeClient = require("tests.helpers.fake_lsp_client")
local FakeTimer = require("tests.helpers.fake_timer")
local Lsp = require("voyager.lsp")
local RequestGroup = require("voyager.lsp.request_group")

local function context()
  return {
    generation = 4,
    request_token = 12,
    origin_node_id = "loc-root",
    bufnr = 3,
    winid = 8,
    project_root = "/project",
    timeout_ms = 1000,
  }
end

local function logical_item(id)
  return { identity = id, location = { identity = id }, raw = { uri = id } }
end

local function fake_group(stage, calls)
  return {
    start = function(opts)
      calls.count = calls.count + 1
      calls.opts = opts
      local handle = { done = false }
      function handle:cancel()
        if not self.done then
          self.done = true
          opts.on_complete({
            status = "cancelled",
            responses = {},
            failures = { { kind = "cancelled", client_id = 1, client_name = "alpha", message = "close" } },
          })
        end
      end
      function handle:is_done()
        return self.done
      end
      opts.on_complete(vim.deepcopy(stage))
      handle.done = true
      if calls.complete_twice then
        opts.on_complete(vim.deepcopy(stage))
      end
      return handle
    end,
  }
end

describe("Voyager standard LSP facade", function()
  it("discovers supporting clients and builds encoding-specific reference params", function()
    local timers = FakeTimer.new()
    local alpha = FakeClient.new({ id = 2, name = "alpha", offset_encoding = "utf-16" })
    local zeta = FakeClient.new({ id = 9, name = "zeta", offset_encoding = "utf-8" })
    local discovery_calls = {}
    local params_calls = {}
    local normalized_responses
    local completed = {}
    local service = Lsp.new({
      actions = Actions,
      normalizer = {
        locations = function(_, responses)
          normalized_responses = responses
          return { logical_item("raw-1"), logical_item("raw-1") }, { { identity = "raw-1" } }, {}, {
            usable_response_count = 2,
            empty_response_count = 0,
            invalid_response_count = 0,
          }
        end,
      },
      request_group = RequestGroup,
      get_clients = function(filter)
        table.insert(discovery_calls, vim.deepcopy(filter))
        return { zeta, alpha }
      end,
      make_position_params = function(winid, encoding)
        table.insert(params_calls, { winid = winid, encoding = encoding })
        return { position = { line = 3, character = encoding == "utf-16" and 4 or 6 } }
      end,
      timer = timers.factory,
      select = function() end,
    })

    local handle = service:start("references", context(), function(outcome)
      table.insert(completed, outcome)
    end)
    assert.same({ { bufnr = 3, method = "textDocument/references" } }, discovery_calls)
    assert.same({
      { winid = 8, encoding = "utf-16" },
      { winid = 8, encoding = "utf-8" },
    }, params_calls)
    assert.same({ includeDeclaration = true }, alpha.requests[1].params.context)
    assert.same({ includeDeclaration = true }, zeta.requests[1].params.context)
    assert.equals(3, alpha.requests[1].params.position.line)

    alpha.name = "mutated"
    alpha.offset_encoding = "utf-32"
    zeta:reply(nil, {})
    alpha:reply(nil, {})

    assert.is_true(handle:is_done())
    assert.equals(1, #completed)
    assert.same({ "alpha", "zeta" }, vim.tbl_map(function(response)
      return response.client.name
    end, normalized_responses))
    assert.same({ "utf-16", "utf-8" }, vim.tbl_map(function(response)
      return response.client.offset_encoding
    end, normalized_responses))
    assert.equals("success", completed[1].status)
    assert.equals("textDocument/references", completed[1].method)
    assert.equals("references", completed[1].label)
    assert.equals("loc-root", completed[1].origin_node_id)
    assert.equals(2, #completed[1].items)
    assert.equals(1, #completed[1].locations)
    assert.same(Actions.get("references"), completed[1].action)
  end)

  it("classifies logical outcomes from usable responses and ordered failures", function()
    local timeout = { kind = "timeout", client_id = 9, client_name = "zeta", message = "late" }
    local protocol = { kind = "protocol", client_id = 9, client_name = "zeta", message = "bad" }
    local normalization = {
      kind = "normalization",
      client_id = 2,
      client_name = "alpha",
      response_index = 1,
      invalid_item_count = 1,
      message = "invalid",
    }
    local cases = {
      {
        name = "valid",
        stage = { status = "success", responses = { { result = {} } }, failures = {} },
        normalized = { { logical_item("one") }, { { identity = "one" } }, {}, 1 },
        status = "success",
      },
      {
        name = "empty",
        stage = { status = "success", responses = { { result = {} } }, failures = {} },
        normalized = { {}, {}, {}, 1 },
        status = "empty",
      },
      {
        name = "partial empty",
        stage = { status = "partial", responses = { { result = {} } }, failures = { protocol } },
        normalized = { {}, {}, {}, 1 },
        status = "partial",
      },
      {
        name = "timeout",
        stage = { status = "timeout", responses = {}, failures = { timeout } },
        normalized = { {}, {}, {}, 0 },
        status = "timeout",
      },
      {
        name = "error",
        stage = { status = "error", responses = {}, failures = { protocol } },
        normalized = { {}, {}, { normalization }, 0 },
        status = "error",
        failures = { normalization, protocol },
      },
    }

    for _, case in ipairs(cases) do
      local group_calls = { count = 0, complete_twice = true }
      local completed = {}
      local service = Lsp.new({
        actions = Actions,
        normalizer = {
          locations = function()
            return vim.deepcopy(case.normalized[1]), vim.deepcopy(case.normalized[2]), vim.deepcopy(case.normalized[3]), {
              usable_response_count = case.normalized[4],
              empty_response_count = case.normalized[4] > 0 and #case.normalized[1] == 0 and 1 or 0,
              invalid_response_count = case.normalized[4] == 0 and 1 or 0,
            }
          end,
        },
        request_group = fake_group(case.stage, group_calls),
        get_clients = function() return { FakeClient.new({ id = 1, name = "alpha" }) } end,
        make_position_params = function() return {} end,
        timer = function() error("fake group owns no timer") end,
        select = function() end,
      })

      local handle = service:start("definition", context(), function(outcome)
        table.insert(completed, outcome)
      end)
      assert.equals(1, group_calls.count, case.name)
      assert.equals(1, #completed, case.name)
      assert.is_true(handle:is_done(), case.name)
      assert.equals(case.status, completed[1].status, case.name)
      assert.equals(#case.normalized[1], #completed[1].items, case.name)
      assert.equals(#case.normalized[2], #completed[1].locations, case.name)
      if case.failures then
        assert.same(case.failures, completed[1].failures, case.name)
      end
    end
  end)

  it("completes unsupported actions without dispatch", function()
    local group_calls = { count = 0 }
    local completed = {}
    local service = Lsp.new({
      actions = Actions,
      normalizer = { locations = function() error("normalizer must not run") end },
      request_group = fake_group({}, group_calls),
      get_clients = function(filter)
        assert.same({ bufnr = 3, method = "textDocument/definition" }, filter)
        return {}
      end,
      make_position_params = function() error("params must not run") end,
      timer = function() error("timer must not run") end,
      select = function() end,
    })

    local handle = service:start("definition", context(), function(outcome)
      table.insert(completed, outcome)
    end)
    assert.is_true(handle:is_done())
    assert.equals(0, group_calls.count)
    assert.equals(1, #completed)
    assert.same({
      status = "unsupported",
      action = Actions.get("definition"),
      method = "textDocument/definition",
      label = "definition",
      origin_node_id = "loc-root",
      items = {},
      locations = {},
      failures = {},
    }, completed[1])
  end)

  it("cancels once while interactive supersession remains a no-op", function()
    local timers = FakeTimer.new()
    local client = FakeClient.new({ id = 1, name = "alpha" })
    local completed = {}
    local service = Lsp.new({
      actions = Actions,
      normalizer = {
        locations = function(_, responses)
          return { logical_item("one") }, { { identity = "one" } }, {}, {
            usable_response_count = #responses,
            empty_response_count = 0,
            invalid_response_count = 0,
          }
        end,
      },
      request_group = RequestGroup,
      get_clients = function() return { client } end,
      make_position_params = function() return {} end,
      timer = timers.factory,
      select = function() end,
    })

    local handle = service:start("definition", context(), function(outcome)
      table.insert(completed, outcome)
    end)
    assert.is_nil(client.requests[1].params.context)
    handle:supersede_interactive()
    client:reply(nil, {})
    assert.equals("success", completed[1].status)
    assert.equals(1, #completed)

    client = FakeClient.new({ id = 1, name = "alpha" })
    completed = {}
    handle = service:start("definition", context(), function(outcome)
      table.insert(completed, outcome)
    end)
    handle:cancel("close")
    assert.equals("cancelled", completed[1].status)
    assert.equals(1, #completed)
    client:reply_late(nil, {})
    assert.equals(1, #completed)
  end)

  it("routes call actions through prepare discovery with facade-level ownership", function()
    local first_client = FakeClient.new({ id = 1, name = "alpha", offset_encoding = "utf-16" })
    local captures = {}
    local completed = {}
    local underlying = { cancel_count = 0, supersede_count = 0, done = false }
    function underlying:cancel()
      self.cancel_count = self.cancel_count + 1
    end
    function underlying:supersede_interactive()
      self.supersede_count = self.supersede_count + 1
    end
    function underlying:is_done()
      return self.done
    end
    local call_hierarchy = {
      start = function(opts)
        table.insert(captures, opts)
        return underlying
      end,
    }
    local service = Lsp.new({
      actions = Actions,
      normalizer = {},
      request_group = { start = function() error("standard request group must not start") end },
      call_hierarchy = call_hierarchy,
      get_clients = function(filter)
        assert.same({ bufnr = 3, method = "textDocument/prepareCallHierarchy" }, filter)
        return { first_client }
      end,
      make_position_params = function() return {} end,
      timer = function() end,
      select = function() end,
    })

    local first_context = context()
    local handle = service:start("incoming_calls", first_context, function(outcome)
      table.insert(completed, outcome)
    end)
    assert.equals(1, #captures)
    assert.equals(12, captures[1].context.request_token)
    assert.equals(1, captures[1].clients[1].id)
    assert.equals("alpha", captures[1].clients[1].name)
    assert.is_true(captures[1].owns_presentation(12))
    handle:supersede_interactive()
    assert.equals(1, underlying.supersede_count)

    local second_context = context()
    second_context.request_token = 13
    service:start("incoming_calls", second_context, function() end)
    assert.is_false(captures[1].owns_presentation(12))
    assert.is_true(captures[2].owns_presentation(13))

    captures[1].on_complete({ status = "empty", items = {}, locations = {}, failures = {} })
    captures[1].on_complete({ status = "error", items = {}, locations = {}, failures = {} })
    assert.equals(1, #completed)
    assert.equals("empty", completed[1].status)
    assert.equals("callHierarchy/incomingCalls", completed[1].method)
  end)
end)
