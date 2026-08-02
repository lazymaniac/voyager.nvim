local Flow = require("voyager.flow")
local Fixtures = require("tests.helpers.flow")

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
end)
