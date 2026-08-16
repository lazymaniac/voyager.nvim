local Recursive = require("voyager.recursive")

local function scheduler(overrides)
  return Recursive.new(vim.tbl_extend("force", {
    seed_id = "A",
    action_names = { "incoming_calls", "outgoing_calls" },
    concurrency = 2,
  }, overrides or {}))
end

describe("Voyager automatic call-graph scheduler", function()
  it("seeds both directions and preserves each direction through its frontier", function()
    local run = scheduler()
    assert.same({
      processed = 0,
      scheduled = 2,
      active = 0,
      depth = 0,
      concurrency = 2,
      cancelled = false,
      issues = 0,
    }, run:status())

    local incoming = assert(run:claim())
    local outgoing = assert(run:claim())
    assert.same({ "incoming_calls", "outgoing_calls" }, { incoming.action_name, outgoing.action_name })
    assert.equals("A", incoming.subject_id)
    assert.equals("A", outgoing.subject_id)

    assert.is_true(run:complete(outgoing, { "callee" }))
    assert.is_nil(run:claim())
    assert.is_true(run:complete(incoming, { "caller" }))

    local callee = assert(run:claim())
    local caller = assert(run:claim())
    assert.same({ "callee", "outgoing_calls" }, { callee.subject_id, callee.action_name })
    assert.same({ "caller", "incoming_calls" }, { caller.subject_id, caller.action_name })
    assert.equals(1, callee.depth)
    assert.equals(1, caller.depth)
    assert.is_true(run:complete(callee, {}))
    assert.is_true(run:complete(caller, {}))
    assert.is_true(run:is_done())
  end)

  it("deduplicates cycles per direction without suppressing the opposite direction", function()
    local run = scheduler({ concurrency = 4 })
    local incoming = assert(run:claim())
    local outgoing = assert(run:claim())
    assert.is_true(run:complete(incoming, { "B", "B" }))
    assert.is_true(run:complete(outgoing, { "B", "B" }))

    local first_b = assert(run:claim())
    local second_b = assert(run:claim())
    assert.same({ "incoming_calls", "outgoing_calls" }, { first_b.action_name, second_b.action_name })
    assert.is_true(run:complete(first_b, { "A", "C" }))
    assert.is_true(run:complete(second_b, { "A", "C" }))

    local first_c = assert(run:claim())
    local second_c = assert(run:claim())
    assert.equals("C", first_c.subject_id)
    assert.equals("C", second_c.subject_id)
    assert.is_true(run:complete(first_c, { "B" }))
    assert.is_true(run:complete(second_c, { "B" }))
    assert.is_true(run:is_done())
    assert.same({ 6, 6, 0, 3 }, {
      run:status().processed,
      run:status().scheduled,
      run:status().active,
      run:status().depth,
    })
  end)

  it("walks an unbounded frontier while respecting the concurrency cap", function()
    local run = scheduler({ concurrency = 1 })
    local incoming = assert(run:claim())
    assert.is_nil(run:claim())
    assert.is_true(run:complete(incoming, {}))

    local item = assert(run:claim())
    assert.equals("outgoing_calls", item.action_name)
    for index = 1, 25 do
      assert.equals(index - 1, item.depth)
      assert.is_true(run:complete(item, { "node-" .. index }))
      item = assert(run:claim())
      assert.equals("outgoing_calls", item.action_name)
      assert.is_nil(run:claim())
    end
    assert.equals(25, item.depth)
    assert.is_true(run:complete(item, {}))
    assert.is_true(run:is_done())
    assert.equals(25, run:status().depth)
    assert.equals(27, run:status().processed)
  end)

  it("accepts a claim once and counts issues once", function()
    local run = scheduler({ concurrency = 1 })
    local item = assert(run:claim())
    local lookalike = vim.deepcopy(item)
    assert.is_false(run:complete(lookalike, {}, true))
    assert.equals(1, run:status().active)

    item.subject_id = "tampered"
    item.action_name = "tampered"
    assert.is_true(run:complete(item, { "B" }, { message = "partial" }))
    assert.is_false(run:complete(item, {}, true))
    assert.equals(1, run:status().issues)

    local other_seed_direction = assert(run:claim())
    assert.equals("outgoing_calls", other_seed_direction.action_name)
    assert.is_true(run:complete(other_seed_direction, {}))
    local child = assert(run:claim())
    assert.same({ "B", "incoming_calls" }, { child.subject_id, child.action_name })
    assert.is_true(run:complete(child, {}))
    assert.is_true(run:is_done())
  end)

  it("cancels queued and active work and rejects late completions", function()
    local run = scheduler()
    local incoming = assert(run:claim())
    local outgoing = assert(run:claim())
    assert.is_true(run:cancel())
    assert.is_false(run:cancel())
    assert.is_true(run:is_done())
    assert.is_nil(run:claim())
    assert.is_false(run:complete(incoming, { "late" }, true))
    assert.is_false(run:complete(outgoing, {}, true))
    assert.same({ true, 0, 0, 2, 0 }, {
      run:status().cancelled,
      run:status().active,
      run:status().processed,
      run:status().scheduled,
      run:status().issues,
    })
  end)

  it("validates constructor inputs and target lists before consuming a claim", function()
    for _, opts in ipairs({
      {},
      { seed_id = "A", action_names = {}, concurrency = 1 },
      { seed_id = "A", action_names = { "incoming_calls", "incoming_calls" }, concurrency = 1 },
      { seed_id = "A", action_names = { "incoming_calls" }, concurrency = 1.5 },
    }) do
      assert.has_error(function()
        Recursive.new(opts)
      end)
    end

    local run = scheduler({ concurrency = 1 })
    local item = assert(run:claim())
    assert.has_error(function()
      run:complete(item, { [2] = "B" })
    end)
    assert.equals(1, run:status().active)
    assert.is_true(run:complete(item, {}))
  end)
end)
