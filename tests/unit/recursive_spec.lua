local Recursive = require("voyager.recursive")

local function scheduler(overrides)
  return Recursive.new(vim.tbl_extend("force", {
    seed_id = "A",
    action_name = "outgoing_calls",
    max_depth = 8,
    max_subjects = 20,
    concurrency = 2,
  }, overrides or {}))
end

describe("Voyager recursive BFS scheduler", function()
  it("claims a bounded FIFO frontier and keeps later levels behind active parents", function()
    local run = scheduler()
    assert.same({
      processed = 0,
      scheduled = 1,
      active = 0,
      depth = 0,
      max_depth = 8,
      max_subjects = 20,
      allowance = 20,
      truncated = false,
      paused = false,
      cancelled = false,
      issues = 0,
    }, run:status())

    local root = assert(run:claim())
    assert.same({ subject_id = "A", action_name = "outgoing_calls", depth = 0 }, root)
    assert.is_nil(run:claim())
    assert.is_true(run:complete(root, { "B", "C" }))

    local first = assert(run:claim())
    local second = assert(run:claim())
    assert.equals("B", first.subject_id)
    assert.equals("C", second.subject_id)
    assert.is_nil(run:claim())

    -- C settles first and queues D, but D cannot leap over the active B level.
    assert.is_true(run:complete(second, { "D" }))
    assert.is_nil(run:claim())
    assert.is_true(run:complete(first, { "E" }))

    local third = assert(run:claim())
    local fourth = assert(run:claim())
    assert.same({ "D", "E" }, { third.subject_id, fourth.subject_id })
    assert.equals(2, third.depth)
    assert.equals(2, fourth.depth)
    assert.is_true(run:complete(third, {}))
    assert.is_true(run:complete(fourth, {}))
    assert.is_true(run:is_done())
    assert.equals(5, run:status().processed)
  end)

  it("terminates cycles and converging routes after one claim per canonical subject", function()
    local run = scheduler({ concurrency = 3 })
    local root = assert(run:claim())
    assert.is_true(run:complete(root, { "B", "C", "B" }))

    local b = assert(run:claim())
    local c = assert(run:claim())
    assert.is_true(run:complete(b, { "A", "D" }))
    assert.is_true(run:complete(c, { "D", "A" }))

    local d = assert(run:claim())
    assert.equals("D", d.subject_id)
    assert.is_true(run:complete(d, { "B" }))
    assert.is_nil(run:claim())
    assert.is_true(run:is_done())
    assert.same({ 4, 4, 0, 3 }, {
      run:status().processed,
      run:status().scheduled,
      run:status().active,
      run:status().depth,
    })
  end)

  it("records boundary edges without scheduling subjects at max depth", function()
    local one_level = scheduler({ max_depth = 1 })
    local root = assert(one_level:claim())
    local targets = { "B", "C" }
    assert.is_true(one_level:complete(root, targets))

    assert.same({ "B", "C" }, targets)
    assert.is_true(one_level:is_done())
    assert.is_false(one_level:is_paused())
    assert.equals(1, one_level:status().scheduled)
    assert.equals(1, one_level:status().depth)
    assert.is_false(one_level:status().truncated)

    local three_levels = scheduler({ max_depth = 3 })
    local a = assert(three_levels:claim())
    assert.is_true(three_levels:complete(a, { "B" }))
    local b = assert(three_levels:claim())
    assert.is_true(three_levels:complete(b, { "C" }))
    local c = assert(three_levels:claim())
    assert.is_true(three_levels:complete(c, { "D" }))
    assert.is_true(three_levels:is_done())
    assert.equals(3, three_levels:status().processed)
    assert.equals(3, three_levels:status().scheduled)
    assert.equals(3, three_levels:status().depth)
    assert.is_false(three_levels:status().truncated)
  end)

  it("retains subject overflow across resumable allowance windows", function()
    local run = scheduler({ max_subjects = 2, concurrency = 2 })
    local root = assert(run:claim())
    assert.is_true(run:complete(root, { "B", "C", "D" }))
    assert.equals(4, run:status().scheduled)

    local b = assert(run:claim())
    assert.equals("B", b.subject_id)
    assert.is_nil(run:claim())
    assert.is_true(run:is_paused())
    assert.is_true(run:status().truncated)
    assert.is_false(run:is_done())
    assert.is_true(run:complete(b, { "E" }))
    assert.equals(5, run:status().scheduled)

    assert.is_true(run:resume())
    assert.equals(4, run:status().allowance)
    assert.is_false(run:is_paused())
    local c = assert(run:claim())
    local d = assert(run:claim())
    assert.same({ "C", "D" }, { c.subject_id, d.subject_id })
    assert.is_true(run:is_paused())
    assert.is_true(run:complete(c, {}))
    assert.is_true(run:complete(d, {}))
    assert.is_true(run:is_paused())

    assert.is_true(run:resume())
    assert.equals(6, run:status().allowance)
    local e = assert(run:claim())
    assert.equals("E", e.subject_id)
    assert.is_true(run:complete(e, {}))
    assert.is_true(run:is_done())
    assert.is_false(run:is_paused())
    assert.is_false(run:status().truncated)
  end)

  it("accepts each claimed item exactly once and counts issues once", function()
    local run = scheduler()
    local item = assert(run:claim())
    local lookalike = vim.deepcopy(item)

    assert.is_false(run:complete(lookalike, {}, true))
    assert.equals(1, run:status().active)
    item.subject_id = "tampered"
    item.depth = 99
    assert.is_true(run:complete(item, { "B" }, { message = "partial" }))
    assert.is_false(run:complete(item, { "C" }, true))
    assert.equals(1, run:status().issues)
    assert.equals(1, run:status().processed)

    local child = assert(run:claim())
    assert.equals("B", child.subject_id)
    assert.equals(1, child.depth)
    assert.is_true(run:complete(child, {}))
    assert.is_true(run:is_done())

    local other = scheduler()
    local foreign = assert(other:claim())
    assert.is_false(run:complete(foreign, {}))
    assert.is_true(other:complete(foreign, {}))
  end)

  it("cancels queued and active work and rejects every late completion", function()
    local run = scheduler()
    local root = assert(run:claim())
    assert.is_true(run:complete(root, { "B", "C", "D" }))
    local b = assert(run:claim())
    local c = assert(run:claim())

    assert.is_true(run:cancel())
    assert.is_false(run:cancel())
    assert.is_true(run:is_done())
    assert.is_false(run:is_paused())
    assert.is_nil(run:claim())
    assert.is_false(run:complete(b, { "E" }, true))
    assert.is_false(run:complete(c, {}, true))
    assert.is_false(run:resume())
    assert.same({ true, 0, 1, 4, 0 }, {
      run:status().cancelled,
      run:status().active,
      run:status().processed,
      run:status().scheduled,
      run:status().issues,
    })
  end)

  it("settles synchronous callback pumps without leaking slots or duplicating work", function()
    local graph = {
      A = { "B", "C" },
      B = { "D", "A" },
      C = { "D", "E" },
      D = { "E" },
      E = {},
    }
    local run = scheduler({ concurrency = 4 })
    local order = {}

    while not run:is_done() do
      local claimed = false
      while true do
        local item = run:claim()
        if not item then
          break
        end
        claimed = true
        table.insert(order, item.subject_id)
        assert.is_true(run:complete(item, graph[item.subject_id]))
      end
      assert.is_true(claimed)
      assert.is_false(run:is_paused())
    end

    assert.same({ "A", "B", "C", "D", "E" }, order)
    assert.same({ 5, 5, 0, 0 }, {
      run:status().processed,
      run:status().scheduled,
      run:status().active,
      run:status().issues,
    })
  end)

  it("validates constructor bounds and target lists before consuming a claim", function()
    for key, value in pairs({ max_depth = 0, max_subjects = -1, concurrency = 1.5 }) do
      assert.has_error(function()
        scheduler({ [key] = value })
      end)
    end
    assert.has_error(function()
      Recursive.new({})
    end)

    local run = scheduler()
    local item = assert(run:claim())
    assert.has_error(function()
      run:complete(item, { [2] = "B" })
    end)
    assert.equals(1, run:status().active)
    assert.is_true(run:complete(item, {}))
  end)
end)
