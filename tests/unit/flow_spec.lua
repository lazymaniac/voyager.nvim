local Flow = require("voyager.flow")
local Fixtures = require("tests.helpers.flow")

local function node_id(kind, value)
  local prefix = kind == "location" and "loc" or kind
  return string.format("%s-%032x", prefix, value)
end

local function location_node(value, path, line, symbol, context)
  local location = Fixtures.location(path, line, symbol, context)
  location.identity = nil
  return {
    id = node_id("loc", value),
    kind = "location",
    location = location,
    note = nil,
    actions = {},
  }
end

local function action_node(value, method, label, results, collapsed)
  return {
    id = node_id("action", value),
    kind = "action",
    method = method,
    label = label,
    collapsed = collapsed or false,
    results = results or {},
  }
end

local function document(root, current_node_id)
  local value = Fixtures.document()
  value.root = root
  value.current_node_id = current_node_id or root.id
  return value
end

local function load(document_value, next_id)
  local now = function()
    return "2026-08-01T19:00:00Z"
  end
  return Flow.from_document(document_value, { now = now, next_id = next_id or select(2, Fixtures.factories()) })
end

describe("Voyager flow", function()
  it("keeps sibling branches while extending a selected result", function()
    local flow = Fixtures.new_flow()
    local first = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/implementation",
      label = "implementations",
      locations = {
        Fixtures.location("lua/mysql.lua", 2, "MysqlStore.save"),
        Fixtures.location("lua/memory.lua", 3, "MemoryStore.save"),
      },
    })
    local mysql_id = first.node_id_by_identity[Fixtures.identity("lua/mysql.lua", 2)]
    flow:set_current(mysql_id)
    flow:commit_navigation({
      origin_node_id = mysql_id,
      method = "textDocument/references",
      label = "references",
      locations = { Fixtures.location("lua/auth.lua", 8, "AuthService.login") },
    })

    assert.equals(2, #flow.root.actions[1].results)
    assert.equals("textDocument/references", flow.root.actions[1].results[1].actions[1].method)
    assert.same({}, flow.root.actions[1].results[2].actions)
  end)

  it("reuses one action and deduplicates repeated results", function()
    local flow = Fixtures.new_flow()
    local mysql = Fixtures.location("lua/mysql.lua", 2, "MysqlStore.save")
    local memory = Fixtures.location("lua/memory.lua", 3, "MemoryStore.save")
    local first = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/implementation",
      label = "implementations",
      locations = { mysql },
    })
    local second = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/implementation",
      label = "implementations",
      locations = { mysql, memory },
    })

    assert.equals(first.action_id, second.action_id)
    assert.equals(first.node_id_by_identity[mysql.identity], second.node_id_by_identity[mysql.identity])
    assert.equals(2, #flow.root.actions[1].results)
  end)

  it("keeps the same destination distinct beneath different ancestors", function()
    local flow = Fixtures.new_flow()
    local branches = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/implementation",
      label = "implementations",
      locations = {
        Fixtures.location("lua/mysql.lua", 2, "MysqlStore.save"),
        Fixtures.location("lua/memory.lua", 3, "MemoryStore.save"),
      },
    })
    local auth = Fixtures.location("lua/auth.lua", 8, "AuthService.login")
    local mysql = flow:commit_navigation({
      origin_node_id = branches.node_id_by_identity[Fixtures.identity("lua/mysql.lua", 2)],
      method = "textDocument/references",
      label = "references",
      locations = { auth },
    })
    local memory = flow:commit_navigation({
      origin_node_id = branches.node_id_by_identity[Fixtures.identity("lua/memory.lua", 3)],
      method = "textDocument/references",
      label = "references",
      locations = { auth },
    })

    assert.not_equals(mysql.node_id_by_identity[auth.identity], memory.node_id_by_identity[auth.identity])
  end)

  it("maps a reverse-route result to its ancestor instead of a new branch", function()
    local Locator = require("voyager.locator")
    local flow = Fixtures.new_flow()
    local site = Fixtures.location("lua/auth.lua", 5, "caller")
    local commit = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/references",
      label = "references",
      locations = { site },
    })
    local site_id = commit.node_id_by_identity[site.identity]
    local back = vim.deepcopy(flow.root.location)
    back.identity = Locator.location_key(back)

    local reverse = flow:commit_navigation({
      origin_node_id = site_id,
      method = "textDocument/definition",
      label = "definition",
      locations = { back },
    })
    assert.equals(flow.root.id, reverse.node_id_by_identity[back.identity])
    assert.is_nil(reverse.action_id)
    assert.is_false(reverse.changed)
    assert.same({}, flow:location(site_id).actions)

    local fresh = Fixtures.location("lua/fresh.lua", 1, "fresh")
    local mixed = flow:commit_navigation({
      origin_node_id = site_id,
      method = "textDocument/definition",
      label = "definition",
      locations = { back, fresh },
    })
    assert.equals(flow.root.id, mixed.node_id_by_identity[back.identity])
    local definition = flow:location(site_id).actions[1]
    assert.equals(1, #definition.results)
    assert.equals(mixed.node_id_by_identity[fresh.identity], definition.results[1].id)
  end)

  it("re-roots a manual jump onto an ancestor without a connector", function()
    local Locator = require("voyager.locator")
    local flow = Fixtures.new_flow()
    local site = Fixtures.location("lua/auth.lua", 5, "caller")
    local commit = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/references",
      label = "references",
      locations = { site },
    })
    local site_id = commit.node_id_by_identity[site.identity]
    assert.is_true(flow:set_current(site_id))

    local back = vim.deepcopy(flow.root.location)
    back.identity = Locator.location_key(back)
    local impl = Fixtures.location("lua/impl.lua", 2, "impl")
    local result = flow:commit_navigation({
      origin_node_id = site_id,
      manual_location = back,
      method = "textDocument/implementation",
      label = "implementations",
      locations = { impl },
    })

    assert.equals(flow.root.id, result.effective_origin_id)
    for _, node in ipairs(flow:dfs()) do
      assert.is_true(node.kind ~= "action" or node.method ~= "voyager/manual")
    end
    local methods = {}
    for _, action in ipairs(flow.root.actions) do
      methods[action.method] = #action.results
    end
    assert.same({ ["textDocument/references"] = 1, ["textDocument/implementation"] = 1 }, methods)
  end)

  it("keeps an empty action visible and treats its repeat as a no-op", function()
    local flow = Fixtures.new_flow()
    local first = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/references",
      label = "references",
      locations = {},
    })
    local second = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/references",
      label = "references",
      locations = {},
    })

    assert.is_true(first.changed)
    assert.is_false(second.changed)
    assert.equals(first.action_id, second.action_id)
    assert.same({}, flow.root.actions[1].results)
  end)

  it("finds nested nodes and returns nil for an unknown ID", function()
    local flow = Fixtures.new_flow()
    local commit = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/definition",
      label = "definition",
      locations = { Fixtures.location("lua/auth.lua", 8, "AuthService.login") },
    })
    local result_id = commit.node_id_by_identity[Fixtures.identity("lua/auth.lua", 8)]

    assert.equals(result_id, flow:find(result_id).id)
    assert.is_nil(flow:find("loc-ffffffffffffffffffffffffffffffff"))
  end)

  it("walks location, action, and result nodes in stable depth-first order", function()
    local flow = Fixtures.new_flow()
    local commit = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/implementation",
      label = "implementations",
      locations = {
        Fixtures.location("lua/mysql.lua", 2, "MysqlStore.save"),
        Fixtures.location("lua/memory.lua", 3, "MemoryStore.save"),
      },
    })
    local mysql_id = commit.node_id_by_identity[Fixtures.identity("lua/mysql.lua", 2)]
    local memory_id = commit.node_id_by_identity[Fixtures.identity("lua/memory.lua", 3)]
    local references = flow:commit_navigation({
      origin_node_id = mysql_id,
      method = "textDocument/references",
      label = "references",
      locations = { Fixtures.location("lua/auth.lua", 8, "AuthService.login") },
    })
    local ids = vim.tbl_map(function(node)
      return node.id
    end, flow:dfs())

    assert.same({
      flow.root.id,
      commit.action_id,
      mysql_id,
      references.action_id,
      references.node_id_by_identity[Fixtures.identity("lua/auth.lua", 8)],
      memory_id,
    }, ids)
  end)

  it("journals persisted changes but ignores semantic no-ops", function()
    local flow = Fixtures.new_flow()
    assert.is_false(flow:is_dirty())
    assert.is_false(flow:set_current(flow.root.id))
    assert.is_true(flow:set_note(flow.root.id, "important for auth"))
    assert.is_false(flow:set_note(flow.root.id, "important for auth"))
    assert.is_true(flow:set_note(flow.root.id, nil))
    assert.is_false(flow:set_note(flow.root.id, nil))
    assert.same({ [flow.root.id] = { note = vim.NIL } }, flow:journal().notes)
  end)

  it("accepts only locations as current and only actions as toggle targets", function()
    local flow = Fixtures.new_flow()
    local commit = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/definition",
      label = "definition",
      locations = {},
    })

    assert.has_error(function()
      flow:set_current(commit.action_id)
    end, "Voyager current node must be a location: " .. commit.action_id)
    assert.has_error(function()
      flow:toggle(flow.root.id)
    end, "Voyager toggle target must be an action: " .. flow.root.id)
    assert.is_true(flow:toggle(commit.action_id))
    assert.is_false(flow:toggle("action-ffffffffffffffffffffffffffffffff"))
  end)

  it("touches display metadata created on a non-root result", function()
    local flow = Fixtures.new_flow()
    local location = Fixtures.location("lua/auth.lua", 8, "AuthService.login", "return auth:login()")
    local commit = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/definition",
      label = "definition",
      locations = { location },
    })
    local result_id = commit.node_id_by_identity[location.identity]

    assert.same({ symbol = true, context = true }, flow:journal().metadata[result_id])
  end)

  it("keeps disk order, retains active IDs on matches, and appends active-only children", function()
    local latest_root = location_node(1, "lua/main.lua", 0, "main")
    local latest_mysql = location_node(12, "lua/mysql.lua", 2, "MysqlStore.save")
    latest_root.actions = {
      action_node(10, "textDocument/references", "stale references", {}),
      action_node(11, "textDocument/implementation", "stale implementations", { latest_mysql }),
    }
    local latest = document(latest_root)

    local active_root = location_node(2, "lua/main.lua", 0, "main")
    local active_mysql = location_node(22, "lua/mysql.lua", 2, "MysqlStore.save")
    active_root.actions = {
      action_node(21, "textDocument/implementation", "wrong label", { active_mysql }),
      action_node(23, "textDocument/definition", "definition", {}),
    }
    local active = load(document(active_root))
    local merged = Flow.merge(latest, active, active:journal(), active._next_id)

    assert.equals(latest.created_at, merged.created_at)
    assert.equals(latest.revision + 1, merged.revision)
    assert.same(
      {
        "textDocument/references",
        "textDocument/implementation",
        "textDocument/definition",
      },
      vim.tbl_map(function(action)
        return action.method
      end, merged.root.actions)
    )
    assert.equals(node_id("action", 10), merged.root.actions[1].id)
    assert.equals(node_id("action", 21), merged.root.actions[2].id)
    assert.equals(node_id("loc", 22), merged.root.actions[2].results[1].id)
    assert.equals(node_id("action", 23), merged.root.actions[3].id)
    assert.same(
      { "references", "implementations", "definition" },
      vim.tbl_map(function(action)
        return action.label
      end, merged.root.actions)
    )
    assert.equals(active.root.id, merged.root.id)
  end)

  it("applies journal precedence to notes, collapse, current, and display metadata", function()
    local latest_root = location_node(1, "lua/main.lua", 0, "main")
    local latest_result = location_node(3, "lua/auth.lua", 8, "disk symbol", "disk context")
    latest_root.note = "disk note"
    latest_root.actions = {
      action_node(2, "textDocument/definition", "definition", { latest_result }, true),
    }
    local latest = document(latest_root, latest_result.id)

    local active_root = location_node(11, "lua/main.lua", 0, "main")
    local active_result = location_node(13, "lua/auth.lua", 8, "old active symbol", "old active context")
    active_root.note = "old active note"
    active_root.actions = {
      action_node(12, "textDocument/definition", "definition", { active_result }, true),
    }
    local active = load(document(active_root))

    local untouched = Flow.merge(latest, active, active:journal(), active._next_id)
    assert.equals("disk note", untouched.root.note)
    assert.is_true(untouched.root.actions[1].collapsed)
    assert.equals("disk symbol", untouched.root.actions[1].results[1].location.symbol)
    assert.equals(active_result.id, untouched.current_node_id)

    assert.is_true(active:set_note(active.root.id, "active note"))
    assert.is_true(active:toggle(active_root.actions[1].id))
    assert.is_true(active:set_current(active_result.id))
    active:commit_navigation({
      origin_node_id = active.root.id,
      method = "textDocument/definition",
      label = "definition",
      locations = { Fixtures.location("lua/auth.lua", 8, "active symbol", "active context") },
    })
    local touched = Flow.merge(latest, active, active:journal(), active._next_id)
    assert.equals("active note", touched.root.note)
    assert.is_false(touched.root.actions[1].collapsed)
    assert.equals("active symbol", touched.root.actions[1].results[1].location.symbol)
    assert.equals("active context", touched.root.actions[1].results[1].location.context)
    assert.equals(active_result.id, touched.current_node_id)

    assert.is_true(active:set_note(active.root.id, nil))
    local cleared = Flow.merge(latest, active, active:journal(), active._next_id)
    assert.is_nil(cleared.root.note)
  end)

  it("remaps colliding saved-only IDs and their current-node reference", function()
    local latest_root = location_node(1, "lua/main.lua", 0, "main")
    local saved_result = location_node(6, "lua/auth.lua", 8, "AuthService.login")
    latest_root.actions = {
      action_node(5, "textDocument/references", "references", { saved_result }),
    }
    local latest = document(latest_root, saved_result.id)

    local active_root = location_node(2, "lua/main.lua", 0, "main")
    active_root.actions = {
      action_node(5, "textDocument/definition", "definition", {
        location_node(6, "lua/mysql.lua", 2, "MysqlStore.save"),
      }),
    }
    local next_value = 90
    local active = load(document(active_root), function(kind)
      next_value = next_value + 1
      return node_id(kind, next_value)
    end)
    local merged = Flow.merge(latest, active, active:journal(), active._next_id)
    local imported = merged.root.actions[1]

    assert.equals("textDocument/references", imported.method)
    assert.not_equals(node_id("action", 5), imported.id)
    assert.not_equals(node_id("loc", 6), imported.results[1].id)
    assert.equals(imported.results[1].id, merged.current_node_id)
    assert.equals(node_id("action", 5), merged.root.actions[2].id)
  end)

  it("rejects changes to immutable root identity", function()
    local latest = Fixtures.document()
    local active_document = Fixtures.document()
    active_document.root.id = node_id("loc", 20)
    active_document.current_node_id = active_document.root.id
    active_document.root.location.symbol = "different-root-symbol"
    local active = load(active_document)

    assert.has_error(function()
      Flow.merge(latest, active, active:journal(), active._next_id)
    end, "Voyager merge requires identical root identity")
  end)

  it("replaces persisted action labels with registry labels on load", function()
    local document_value = Fixtures.document()
    document_value.root.actions = {
      action_node(2, "textDocument/implementation", "obsolete label", {}),
    }
    local flow = load(document_value)

    assert.equals("implementations", flow.root.actions[1].label)
    assert.is_false(flow:is_dirty())
  end)
end)
