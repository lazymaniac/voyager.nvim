local Flow = require("voyager.flow")
local Locator = require("voyager.locator")
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

local function query_anchor(path, line, start_character, end_character, line_text)
  return {
    locator = { kind = "project", path = path },
    range = {
      start = { line = line, character = start_character },
      ["end"] = { line = line, character = end_character },
    },
    line_text = line_text,
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

  it("maps a destination recorded under another branch to the existing node", function()
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
      label = "usages",
      locations = { auth },
    })
    local memory = flow:commit_navigation({
      origin_node_id = branches.node_id_by_identity[Fixtures.identity("lua/memory.lua", 3)],
      method = "textDocument/references",
      label = "usages",
      locations = { auth },
    })

    assert.equals(mysql.node_id_by_identity[auth.identity], memory.node_id_by_identity[auth.identity])
    assert.is_string(memory.action_id)
    assert.is_true(memory.changed)
    local memory_node = flow:location(branches.node_id_by_identity[Fixtures.identity("lua/memory.lua", 3)])
    assert.equals(memory.action_id, memory_node.actions[1].id)
    assert.same({}, memory_node.actions[1].results)
    assert.same({ mysql.node_id_by_identity[auth.identity] }, memory_node.actions[1].target_ids)
  end)

  it("adds only unrecorded destinations when reference sets overlap across the tree", function()
    local flow = Fixtures.new_flow()
    local site_a = Fixtures.location("lua/service.lua", 4, "Service.accept")
    local site_b = Fixtures.location("lua/handler.lua", 9, "Handler.on_event")
    local first = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/references",
      label = "usages",
      locations = { site_a, site_b },
    })
    local a_id = first.node_id_by_identity[site_a.identity]

    -- Re-running references one level deeper returns the overlapping set plus
    -- one genuinely new site; only the new site may grow the tree.
    local site_c = Fixtures.location("lua/worker.lua", 12, "Worker.run")
    local second = flow:commit_navigation({
      origin_node_id = a_id,
      method = "textDocument/references",
      label = "usages",
      locations = { site_b, site_c },
    })

    assert.equals(first.node_id_by_identity[site_b.identity], second.node_id_by_identity[site_b.identity])
    local nested = flow:location(a_id).actions[1]
    assert.equals(1, #nested.results)
    assert.equals(second.node_id_by_identity[site_c.identity], nested.results[1].id)
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
    assert.is_string(reverse.action_id)
    assert.is_true(reverse.changed)
    assert.same({ flow.root.id }, flow:action_target_ids(reverse.action_id))
    assert.same({}, flow:find(reverse.action_id).results)

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
    assert.same({ flow.root.id, definition.results[1].id }, definition.target_ids)
  end)

  it("persists complete reverse-call relationships without duplicating canonical locations", function()
    local flow = Fixtures.new_flow()
    local callee = Fixtures.location("lua/callee.lua", 4, "callee")
    local outgoing = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { callee },
    })
    local callee_id = outgoing.node_id_by_identity[callee.identity]
    local caller = vim.deepcopy(flow.root.location)
    caller.identity = Fixtures.identity("lua/main.lua", 0)

    local incoming = flow:commit_navigation({
      origin_node_id = callee_id,
      method = "callHierarchy/incomingCalls",
      label = "callers",
      locations = { caller },
    })

    local action = assert(flow:action_for(callee_id, "callHierarchy/incomingCalls"))
    assert.equals(incoming.action_id, action.id)
    assert.same({ flow.root.id }, flow:action_target_ids(action))
    assert.same({}, action.results)
    assert.equals("complete", action.query_status)
    assert.equals(2, #vim.tbl_filter(function(node)
      return node.kind == "location"
    end, flow:dfs()))
  end)

  it("orders mixed existing and fresh targets and refreshes canonical metadata", function()
    local flow = Fixtures.new_flow()
    local existing = Fixtures.location("lua/existing.lua", 2, "old-name", "old context")
    local first = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/implementation",
      label = "implementations",
      locations = { existing },
    })
    local existing_id = first.node_id_by_identity[existing.identity]
    local other = Fixtures.location("lua/other.lua", 3, "other")
    local branch = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/declaration",
      label = "declaration",
      locations = { other },
    })
    local other_id = branch.node_id_by_identity[other.identity]
    local refreshed = Fixtures.location("lua/existing.lua", 2, "new-name", "new context")
    refreshed.symbol_kind = "method"
    local fresh = Fixtures.location("lua/fresh.lua", 5, "fresh")

    local mixed = flow:commit_navigation({
      origin_node_id = other_id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { refreshed, fresh, refreshed },
      query_status = "partial",
    })
    local action = assert(flow:action_for(other_id, "callHierarchy/outgoingCalls"))
    local fresh_id = mixed.node_id_by_identity[fresh.identity]

    assert.same({ existing_id, fresh_id }, action.target_ids)
    assert.equals(1, #action.results)
    assert.equals(fresh_id, action.results[1].id)
    assert.equals("partial", action.query_status)
    assert.equals("new-name", flow:location(existing_id).location.symbol)
    assert.equals("new context", flow:location(existing_id).location.context)
    assert.equals("method", flow:location(existing_id).location.symbol_kind)
  end)

  it("replaces targets exactly while retaining canonical storage for reuse", function()
    local flow = Fixtures.new_flow()
    local first = Fixtures.location("lua/first.lua", 2, "first")
    local second = Fixtures.location("lua/second.lua", 3, "second")
    local initial = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { first, second },
    })
    local first_id = initial.node_id_by_identity[first.identity]
    local second_id = initial.node_id_by_identity[second.identity]

    local subset = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { second },
      replace_targets = true,
    })
    local action = assert(flow:action_for(flow.root.id, "callHierarchy/outgoingCalls"))

    assert.equals(initial.action_id, subset.action_id)
    assert.is_true(subset.changed)
    assert.same({ second_id }, action.target_ids)
    assert.same(
      { first_id, second_id },
      vim.tbl_map(function(result)
        return result.id
      end, action.results)
    )
    assert.equals(first_id, flow:location(first_id).id)
    assert.equals(second_id, flow:location(second_id).id)

    local empty = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = {},
      replace_targets = true,
    })

    assert.is_true(empty.changed)
    assert.same({}, action.target_ids)
    assert.equals(2, #action.results)
    assert.equals(first_id, flow:location(first_id).id)
    assert.equals(second_id, flow:location(second_id).id)

    local reused = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "callHierarchy/incomingCalls",
      label = "callers",
      locations = { first },
    })
    local incoming = assert(flow:action_for(flow.root.id, "callHierarchy/incomingCalls"))

    assert.equals(first_id, reused.node_id_by_identity[first.identity])
    assert.same({ first_id }, incoming.target_ids)
    assert.same({}, incoming.results)
    assert.equals(2, #action.results)
  end)

  it("treats an unchanged exact target replacement as a no-op", function()
    local flow = Fixtures.new_flow()
    local first = Fixtures.location("lua/first.lua", 2, "first")
    local second = Fixtures.location("lua/second.lua", 3, "second")
    local initial = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { first, second },
    })

    local replacement = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { first, second },
      replace_targets = true,
    })

    assert.equals(initial.action_id, replacement.action_id)
    assert.is_false(replacement.changed)
    assert.same({
      initial.node_id_by_identity[first.identity],
      initial.node_id_by_identity[second.identity],
    }, flow:action_target_ids(replacement.action_id))
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

  it("threads exact target replacement through staged manual navigation", function()
    local flow = Fixtures.new_flow()
    local manual = Fixtures.location("lua/manual.lua", 1, "manual")
    local first = Fixtures.location("lua/first.lua", 2, "first")
    local second = Fixtures.location("lua/second.lua", 3, "second")
    local initial = flow:commit_navigation({
      origin_node_id = flow.root.id,
      manual_location = manual,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { first, second },
    })

    local replacement = flow:commit_navigation({
      origin_node_id = flow.root.id,
      manual_location = manual,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { second },
      replace_targets = true,
    })
    local action = assert(flow:action_for(initial.effective_origin_id, "callHierarchy/outgoingCalls"))

    assert.equals(initial.action_id, replacement.action_id)
    assert.same({ replacement.node_id_by_identity[second.identity] }, action.target_ids)
    assert.equals(2, #action.results)
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

  it("deletes branches, relocates current, and refuses the root", function()
    local flow = Fixtures.branched_flow()
    local implementations = flow.root.actions[1]
    local mysql = implementations.results[1]
    local nested = flow:commit_navigation({
      origin_node_id = mysql.id,
      method = "textDocument/references",
      label = "references",
      locations = { Fixtures.location("lua/auth.lua", 8, "AuthService.login") },
    })
    local auth_id = nested.node_id_by_identity[Fixtures.identity("lua/auth.lua", 8)]
    assert.is_true(flow:set_current(auth_id))

    assert.is_false(flow:delete(flow.root.id))
    assert.is_false(flow:delete("loc-unknown"))

    assert.is_true(flow:delete(mysql.id))
    assert.is_nil(flow:find(mysql.id))
    assert.is_nil(flow:find(auth_id))
    assert.equals(flow.root.id, flow.current_node_id)
    assert.equals(1, #implementations.results)
    local journal = flow:journal()
    assert.is_true(journal.deleted[implementations.id][Fixtures.identity("lua/mysql.lua", 2)])

    assert.is_true(flow:delete(implementations.id))
    assert.same({}, flow.root.actions)
    journal = flow:journal()
    assert.is_true(journal.deleted[flow.root.id]["textDocument/implementation"])
  end)

  it("does not resurrect a deleted location after its identity was enriched", function()
    local latest_result = location_node(3, "lua/auth.lua", 8, "login")
    local latest_root = location_node(1, "lua/main.lua", 0, "main")
    latest_root.actions = { action_node(2, "textDocument/references", "usages", { latest_result }) }
    local latest = document(latest_root)
    local active = load(latest)
    local anchor = query_anchor("lua/auth.lua", 8, 9, 14, "function login()")

    assert.is_true(active:apply_symbol(latest_result.id, "AuthService.login", "method", anchor))
    local enriched_identity = Locator.location_key(active:location(latest_result.id).location)
    assert.is_true(active:delete(latest_result.id))
    local deleted = active:journal().deleted[active.root.actions[1].id]
    assert.is_true(deleted[Fixtures.identity("lua/auth.lua", 8)])
    assert.is_true(deleted[enriched_identity])

    local merged = Flow.merge(latest, active, active:journal(), active._next_id)
    local merged_flow = load(merged)
    local references = assert(merged_flow:action_for(merged_flow.root.id, "textDocument/references"))
    assert.same({}, references.results)
    assert.same({}, references.target_ids)
    assert.is_nil(merged_flow:location(latest_result.id))
  end)

  it("prunes cross-branch targets when their canonical storage subtree is deleted", function()
    local flow = Fixtures.new_flow()
    local first = Fixtures.location("lua/first.lua", 1, "first")
    local second = Fixtures.location("lua/second.lua", 2, "second")
    local branches = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/implementation",
      label = "implementations",
      locations = { first, second },
    })
    local first_id = branches.node_id_by_identity[first.identity]
    local second_id = branches.node_id_by_identity[second.identity]
    local link = flow:commit_navigation({
      origin_node_id = first_id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { second },
    })
    assert.same({ second_id }, flow:action_target_ids(link.action_id))

    assert.is_true(flow:delete(second_id))
    assert.same({}, flow:action_target_ids(link.action_id))
    assert.is_nil(flow:location(second_id))
  end)

  it("unlinks one relationship occurrence without deleting canonical storage", function()
    local flow = Fixtures.new_flow()
    local first = Fixtures.location("lua/first.lua", 1, "first")
    local second = Fixtures.location("lua/second.lua", 2, "second")
    local branches = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/implementation",
      label = "implementations",
      locations = { first, second },
    })
    local first_id = branches.node_id_by_identity[first.identity]
    local second_id = branches.node_id_by_identity[second.identity]
    local link = flow:commit_navigation({
      origin_node_id = first_id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { second },
    })
    assert.is_true(flow:set_note(second_id, "keep this node"))
    assert.is_true(flow:set_current(second_id))

    assert.is_true(flow:unlink_target(branches.action_id, second_id))
    assert.same({ first_id }, flow:action_target_ids(branches.action_id))
    assert.same({ second_id }, flow:action_target_ids(link.action_id))
    assert.equals(2, #flow:find(branches.action_id).results)
    assert.equals("keep this node", flow:location(second_id).note)
    assert.equals(second_id, flow.current_node_id)
    assert.is_true(flow:journal().relationships[branches.action_id].removed_target_ids[second_id])
    assert.is_false(flow:unlink_target(branches.action_id, second_id))
    assert.is_false(flow:unlink_target("action-missing", second_id))
  end)

  it("deletes an action relation while re-homing storage used by surviving links", function()
    local flow = Fixtures.new_flow()
    local first = Fixtures.location("lua/first.lua", 1, "first")
    local second = Fixtures.location("lua/second.lua", 2, "second")
    local ownership = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/implementation",
      label = "implementations",
      locations = { first, second },
    })
    local first_id = ownership.node_id_by_identity[first.identity]
    local second_id = ownership.node_id_by_identity[second.identity]
    local surviving = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/references",
      label = "usages",
      locations = { second },
    })
    flow:commit_navigation({
      origin_node_id = first_id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { second },
    })
    assert.is_true(flow:set_note(second_id, "shared history"))
    assert.is_true(flow:set_current(second_id))
    local latest = document(vim.deepcopy(flow.root), flow.current_node_id)

    assert.is_true(flow:delete_action_relation(ownership.action_id))
    assert.is_nil(flow:action_for(flow.root.id, "textDocument/implementation"))
    assert.same({ second_id }, flow:action_target_ids(surviving.action_id))
    assert.equals("shared history", flow:location(second_id).note)
    assert.is_table(flow:action_for(first_id, "callHierarchy/outgoingCalls"))
    assert.equals(second_id, flow.current_node_id)

    local merged = Flow.merge(latest, flow, flow:journal(), flow._next_id)
    local merged_flow = load(merged)
    assert.is_nil(merged_flow:action_for(merged_flow.root.id, "textDocument/implementation"))
    local merged_surviving = assert(merged_flow:action_for(merged_flow.root.id, "textDocument/references"))
    assert.same({ second_id }, merged_surviving.target_ids)
    assert.equals("shared history", merged_flow:location(second_id).note)
    assert.is_table(merged_flow:location(first_id))
    assert.equals(second_id, merged.current_node_id)

    local isolated = Fixtures.new_flow()
    local only = isolated:commit_navigation({
      origin_node_id = isolated.root.id,
      method = "textDocument/definition",
      label = "definition",
      locations = { Fixtures.location("lua/only.lua", 1, "only") },
    })
    local only_id = only.node_id_by_identity[Fixtures.identity("lua/only.lua", 1)]
    assert.is_true(isolated:delete_action_relation(only.action_id))
    local archive = assert(isolated:action_for(isolated.root.id, "voyager/archive"))
    assert.same({}, archive.target_ids)
    assert.equals(only_id, archive.results[1].id)
    assert.is_table(isolated:location(only_id))
  end)

  it("deletes manual relations through an invisible archive and removes the empty carrier", function()
    local flow = Fixtures.new_flow()
    local manual = Fixtures.location("lua/manual.lua", 1, "manual")
    local target = Fixtures.location("lua/target.lua", 2, "target")
    local commit = flow:commit_navigation({
      origin_node_id = flow.root.id,
      manual_location = manual,
      method = "textDocument/definition",
      label = "definition",
      locations = { target },
    })
    local manual_id = commit.effective_origin_id
    local manual_action = assert(flow:action_for(flow.root.id, "voyager/manual"))
    assert.is_true(flow:set_current(manual_id))
    local latest_with_manual = document(vim.deepcopy(flow.root), flow.current_node_id)

    assert.is_true(flow:delete_action_relation(manual_action.id))
    assert.is_nil(flow:action_for(flow.root.id, "voyager/manual"))
    local archive = assert(flow:action_for(flow.root.id, "voyager/archive"))
    assert.same({}, archive.target_ids)
    assert.equals(manual_id, archive.results[1].id)
    assert.equals("textDocument/definition", flow:location(manual_id).actions[1].method)
    assert.equals(manual_id, flow.current_node_id)

    local merged_manual_delete = Flow.merge(latest_with_manual, flow, flow:journal(), flow._next_id)
    local merged_manual_flow = load(merged_manual_delete)
    assert.is_nil(merged_manual_flow:action_for(merged_manual_flow.root.id, "voyager/manual"))
    assert.is_table(merged_manual_flow:action_for(merged_manual_flow.root.id, "voyager/archive"))
    assert.is_table(merged_manual_flow:location(manual_id))

    local latest_with_archive = document(vim.deepcopy(flow.root), flow.current_node_id)
    local active = load(latest_with_archive)
    assert.is_true(active:delete(manual_id))
    assert.is_nil(active:action_for(active.root.id, "voyager/archive"))
    assert.is_nil(active:location(manual_id))
    assert.is_true(active:journal().deleted[active.root.id]["voyager/archive"])
    assert.equals(active.root.id, active.current_node_id)

    local merged_archive_delete = Flow.merge(latest_with_archive, active, active:journal(), active._next_id)
    local merged_archive_flow = load(merged_archive_delete)
    assert.is_nil(merged_archive_flow:action_for(merged_archive_flow.root.id, "voyager/archive"))
    assert.is_nil(merged_archive_flow:location(manual_id))
    assert.equals(merged_archive_flow.root.id, merged_archive_flow.current_node_id)
  end)

  it("does not resurrect cleared history when an archive is recreated before merge", function()
    local flow = Fixtures.new_flow()
    local old = Fixtures.location("lua/old.lua", 1, "old")
    local fresh = Fixtures.location("lua/fresh.lua", 2, "fresh")
    local old_commit = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/definition",
      label = "definition",
      locations = { old },
    })
    local fresh_commit = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/implementation",
      label = "implementations",
      locations = { fresh },
    })
    local old_id = old_commit.node_id_by_identity[old.identity]
    local fresh_id = fresh_commit.node_id_by_identity[fresh.identity]
    assert.is_true(flow:delete_action_relation(old_commit.action_id))
    local latest = document(vim.deepcopy(flow.root), flow.current_node_id)
    local active = load(latest)

    assert.is_true(active:delete(old_id))
    assert.is_nil(active:action_for(active.root.id, "voyager/archive"))
    local implementation = assert(active:action_for(active.root.id, "textDocument/implementation"))
    assert.is_true(active:delete_action_relation(implementation.id))
    local recreated = assert(active:action_for(active.root.id, "voyager/archive"))
    assert.same(
      { fresh_id },
      vim.tbl_map(function(result)
        return result.id
      end, recreated.results)
    )

    local merged = Flow.merge(latest, active, active:journal(), active._next_id)
    local merged_flow = load(merged)
    local archive = assert(merged_flow:action_for(merged_flow.root.id, "voyager/archive"))
    assert.same(
      { fresh_id },
      vim.tbl_map(function(result)
        return result.id
      end, archive.results)
    )
    assert.is_nil(merged_flow:location(old_id))
    assert.is_table(merged_flow:location(fresh_id))
  end)

  it("treats a deleted then recreated relation as fresh during save merge", function()
    local flow = Fixtures.new_flow()
    local old = Fixtures.location("lua/old.lua", 1, "old")
    local fresh = Fixtures.location("lua/fresh.lua", 2, "fresh")
    local original = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "callHierarchy/incomingCalls",
      label = "callers",
      locations = { old },
    })
    local old_id = original.node_id_by_identity[old.identity]
    local latest = document(vim.deepcopy(flow.root), flow.current_node_id)

    assert.is_true(flow:delete_action_relation(original.action_id))
    local recreated = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "callHierarchy/incomingCalls",
      label = "callers",
      locations = { fresh },
      query_status = "complete",
    })
    local fresh_id = recreated.node_id_by_identity[fresh.identity]

    local merged = Flow.merge(latest, flow, flow:journal(), flow._next_id)
    local merged_flow = load(merged)
    local callers = assert(merged_flow:action_for(merged_flow.root.id, "callHierarchy/incomingCalls"))
    local archive = assert(merged_flow:action_for(merged_flow.root.id, "voyager/archive"))

    assert.same({ fresh_id }, callers.target_ids)
    assert.same(
      { fresh_id },
      vim.tbl_map(function(result)
        return result.id
      end, callers.results)
    )
    assert.same(
      { old_id },
      vim.tbl_map(function(result)
        return result.id
      end, archive.results)
    )
    assert.is_table(merged_flow:location(old_id))
    assert.is_table(merged_flow:location(fresh_id))
  end)

  it("keeps deleted branches out of a save merge while importing new ones", function()
    local Locator = require("voyager.locator")
    local active = Fixtures.new_flow()
    local site = Fixtures.location("lua/site.lua", 1, "site")
    local extra = Fixtures.location("lua/extra.lua", 2, "extra")
    local other = Fixtures.location("lua/other.lua", 3, "other")
    local references = active:commit_navigation({
      origin_node_id = active.root.id,
      method = "textDocument/references",
      label = "references",
      locations = { site, extra },
    })
    local definition = active:commit_navigation({
      origin_node_id = active.root.id,
      method = "textDocument/definition",
      label = "definition",
      locations = { other },
    })
    assert.is_true(active:delete(references.node_id_by_identity[extra.identity]))
    assert.is_true(active:delete(definition.action_id))

    local latest_root = location_node(1, "lua/main.lua", 0, "main")
    latest_root.actions = {
      action_node(2, "textDocument/references", "references", {
        location_node(3, "lua/site.lua", 1, "site"),
        location_node(4, "lua/extra.lua", 2, "extra"),
      }),
      action_node(5, "textDocument/definition", "definition", {
        location_node(6, "lua/other.lua", 3, "other"),
      }),
      action_node(7, "textDocument/implementation", "implementations", {
        location_node(8, "lua/impl.lua", 4, "impl"),
      }),
    }
    local merged = Flow.merge(document(latest_root), active, active:journal(), select(2, Fixtures.factories()))

    local methods = {}
    for _, action in ipairs(merged.root.actions) do
      local identities = {}
      for _, result in ipairs(action.results) do
        table.insert(identities, Locator.location_key(result.location))
      end
      methods[action.method] = identities
    end
    assert.same({ Fixtures.identity("lua/site.lua", 1) }, methods["textDocument/references"])
    assert.is_nil(methods["textDocument/definition"])
    assert.same({ Fixtures.identity("lua/impl.lua", 4) }, methods["textDocument/implementation"])
  end)

  it("collapses and expands every action at once", function()
    local flow = Fixtures.branched_flow()
    flow:commit_navigation({
      origin_node_id = flow.root.actions[1].results[1].id,
      method = "textDocument/references",
      label = "references",
      locations = { Fixtures.location("lua/auth.lua", 8, "AuthService.login") },
    })

    assert.is_true(flow:set_all_collapsed(true))
    for _, node in ipairs(flow:dfs()) do
      assert.is_true(node.kind ~= "action" or node.collapsed)
    end
    assert.is_false(flow:set_all_collapsed(true))
    assert.is_true(flow:set_all_collapsed(false))
    for _, node in ipairs(flow:dfs()) do
      assert.is_true(node.kind ~= "action" or not node.collapsed)
    end

    local first_action = flow.root.actions[1]
    assert.is_true(flow:set_collapsed(first_action.id, true))
    assert.is_false(flow:set_collapsed(first_action.id, true))
    assert.is_true(flow:set_collapsed(first_action.id, false))
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
    assert.equals(commit.action_id, flow:action_for(flow.root.id, "textDocument/definition").id)
    assert.is_nil(flow:action_for(flow.root.id, "textDocument/references"))
    assert.same({ result_id }, flow:action_target_ids(commit.action_id))
    assert.same({}, flow:action_target_ids("action-ffffffffffffffffffffffffffffffff"))
  end)

  it("finds the first active-edge path and excludes detached storage ancestry", function()
    local flow = Fixtures.new_flow()
    local first = Fixtures.location("lua/first.lua", 1, "first")
    local second = Fixtures.location("lua/second.lua", 2, "second")
    local third = Fixtures.location("lua/third.lua", 3, "third")
    local ownership = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/implementation",
      label = "implementations",
      locations = { first, second, third },
    })
    local first_id = ownership.node_id_by_identity[first.identity]
    local second_id = ownership.node_id_by_identity[second.identity]
    local third_id = ownership.node_id_by_identity[third.identity]
    flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/implementation",
      label = "implementations",
      locations = { first, third },
      replace_targets = true,
    })
    local first_link = flow:commit_navigation({
      origin_node_id = first_id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { second },
    })
    local third_link = flow:commit_navigation({
      origin_node_id = third_id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { second },
    })
    local root_location = vim.deepcopy(flow.root.location)
    root_location.identity = Fixtures.identity("lua/main.lua", 0)
    flow:commit_navigation({
      origin_node_id = second_id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { root_location },
    })

    assert.same({ flow.root.id, first_id, second_id }, flow:path_ids(second_id))
    assert.is_true(flow:unlink_target(first_link.action_id, second_id))
    assert.same({ flow.root.id, third_id, second_id }, flow:path_ids(second_id))
    assert.is_true(flow:unlink_target(third_link.action_id, second_id))
    assert.same({}, flow:path_ids(second_id))
    assert.same({}, flow:path_ids("loc-missing"))
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

  it("does not let a stale supplied identity erase an anchored identity", function()
    local flow = Fixtures.new_flow()
    local location = Fixtures.location("lua/auth.lua", 8, "AuthService.login")
    local first = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/references",
      label = "usages",
      locations = { location },
    })
    local result_id = first.node_id_by_identity[location.identity]
    local anchored = vim.deepcopy(location)
    anchored.query_anchor = {
      locator = { kind = "project", path = "lua/service.lua" },
      range = {
        start = { line = 3, character = 9 },
        ["end"] = { line = 3, character = 14 },
      },
      line_text = "function login()",
    }

    local anchored_commit = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "callHierarchy/incomingCalls",
      label = "callers",
      locations = { anchored },
    })
    local anchored_identity = Locator.location_key(anchored)
    local anchored_id = assert(anchored_commit.node_id_by_identity[anchored_identity])

    assert.not_equals(result_id, anchored_id)
    assert.is_nil(flow:location(result_id).location.query_anchor)
    assert.same(anchored.query_anchor, flow:location(anchored_id).location.query_anchor)
    assert.equals(anchored_id, anchored_commit.node_id_by_identity[anchored.identity])
    assert.is_true(flow:journal().metadata[anchored_id].query_anchor)

    local mixed = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/implementation",
      label = "implementations",
      locations = { location, anchored },
    })
    assert.equals(result_id, mixed.node_id_by_identity[location.identity])
    assert.equals(anchored_id, mixed.node_id_by_identity[anchored_identity])
  end)

  it("separates opposite semantic anchors and canonicalizes identical ones", function()
    local flow = Fixtures.new_flow()
    local first = Fixtures.location("lua/calls.lua", 8, "first")
    first.query_anchor = query_anchor("lua/first.lua", 2, 9, 14, "function first()")
    local second = vim.deepcopy(first)
    second.symbol = "second"
    second.query_anchor = query_anchor("lua/second.lua", 4, 9, 15, "function second()")
    local duplicate = vim.deepcopy(first)
    duplicate.context = "refreshed context"

    local commit = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { first, second, duplicate },
    })
    local first_identity = Locator.location_key(first)
    local second_identity = Locator.location_key(second)
    local first_id = assert(commit.node_id_by_identity[first_identity])
    local second_id = assert(commit.node_id_by_identity[second_identity])

    assert.not_equals(first_id, second_id)
    assert.equals(2, #flow.root.actions[1].results)
    assert.equals("refreshed context", flow:location(first_id).location.context)

    local repeated = vim.deepcopy(first)
    repeated.context = "latest context"
    repeated.query_anchor.line_text = "function first() -- metadata only"
    local refresh = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "callHierarchy/incomingCalls",
      label = "callers",
      locations = { repeated },
    })

    assert.equals(first_id, refresh.node_id_by_identity[Locator.location_key(repeated)])
    assert.equals("latest context", flow:location(first_id).location.context)
    assert.same(repeated.query_anchor, flow:location(first_id).location.query_anchor)
  end)

  it("marks visited on creation, navigation, and load", function()
    local flow = Fixtures.new_flow()
    assert.is_true(flow.root.visited)
    local location = Fixtures.location("lua/auth.lua", 8, "AuthService.login")
    local commit = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/definition",
      label = "definition",
      locations = { location },
    })
    local result_id = commit.node_id_by_identity[location.identity]
    assert.is_nil(flow:location(result_id).visited)
    assert.is_true(flow:set_current(result_id))
    assert.is_true(flow:location(result_id).visited)

    local loaded_result = location_node(3, "lua/auth.lua", 8, "AuthService.login")
    local loaded_root = location_node(1, "lua/main.lua", 0, "main")
    loaded_root.actions = { action_node(2, "textDocument/definition", "definition", { loaded_result }) }
    local loaded = load(document(loaded_root, loaded_result.id))
    assert.is_true(loaded:location(loaded_result.id).visited)
    assert.is_nil(loaded:location(loaded_root.id).visited)
  end)

  it("applies enrichment to symbol and kind but never renames the root", function()
    local flow = Fixtures.new_flow()
    local location = Fixtures.location("lua/auth.lua", 8, "login")
    local commit = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/references",
      label = "usages",
      locations = { location },
    })
    local result_id = commit.node_id_by_identity[location.identity]

    local anchor = query_anchor("lua/auth.lua", 8, 9, 14, "function login()")
    assert.is_true(flow:apply_symbol(result_id, "AuthService.login", "method", anchor))
    local node = flow:location(result_id)
    assert.equals("AuthService.login", node.location.symbol)
    assert.equals("method", node.location.symbol_kind)
    assert.same(anchor, node.location.query_anchor)
    assert.is_true(flow:journal().metadata[result_id].symbol)
    assert.is_true(flow:journal().metadata[result_id].query_anchor)
    assert.is_false(flow:apply_symbol(result_id, "AuthService.login", "method", anchor))

    local anchored = vim.deepcopy(location)
    anchored.symbol = "AuthService.login"
    anchored.symbol_kind = "method"
    anchored.query_anchor = vim.deepcopy(anchor)
    local canonical = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { anchored },
    })
    assert.equals(result_id, canonical.node_id_by_identity[Locator.location_key(anchored)])

    local recreated = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/references",
      label = "usages",
      locations = { location },
    })
    assert.not_equals(result_id, recreated.node_id_by_identity[location.identity])

    assert.is_true(flow:apply_symbol(flow.root.id, "Renamed.main", "function", anchor))
    assert.equals("main", flow.root.location.symbol)
    assert.equals("function", flow.root.location.symbol_kind)
    assert.is_nil(flow.root.location.query_anchor)
    assert.is_false(flow:apply_symbol("loc-ffffffffffffffffffffffffffffffff", "x", "y"))
  end)

  it("keeps a call-hierarchy subject authoritative during later enrichment", function()
    local flow = Fixtures.new_flow()
    local call_site = Fixtures.location("lua/caller.lua", 8, "ProtocolCaller")
    call_site.symbol_kind = "function"
    local protocol_anchor = query_anchor("lua/caller.lua", 3, 9, 23, "function ProtocolCaller()")
    call_site.query_anchor = protocol_anchor
    local commit = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "callHierarchy/incomingCalls",
      label = "callers",
      locations = { call_site },
    })
    local result_id = commit.node_id_by_identity[call_site.identity]
    local semantic_anchor = query_anchor("lua/caller.lua", 7, 9, 18, "function Enclosing()")

    assert.is_false(flow:apply_symbol(result_id, "Enclosing", "method", semantic_anchor))
    local node = flow:location(result_id)
    assert.equals("ProtocolCaller", node.location.symbol)
    assert.same(protocol_anchor, node.location.query_anchor)
    assert.equals("function", node.location.symbol_kind)

    local ordinary = vim.deepcopy(call_site)
    ordinary.symbol = "Enclosing"
    ordinary.query_anchor = nil
    flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/references",
      label = "usages",
      locations = { ordinary },
    })
    assert.equals("ProtocolCaller", flow:location(result_id).location.symbol)
    assert.same(protocol_anchor, flow:location(result_id).location.query_anchor)
  end)

  it("merges identity-changing enrichment without duplicating its persisted location", function()
    local latest_result = location_node(3, "lua/auth.lua", 8, "disk.symbol")
    latest_result.visited = true
    latest_result.location.symbol_kind = "method"
    local latest_root = location_node(1, "lua/main.lua", 0, "main")
    latest_root.actions = { action_node(2, "textDocument/definition", "definition", { latest_result }) }
    local latest = document(latest_root)

    local active_result = location_node(13, "lua/auth.lua", 8, "active.symbol")
    local active_root = location_node(11, "lua/main.lua", 0, "main")
    active_root.actions = { action_node(12, "textDocument/definition", "definition", { active_result }) }
    local active = load(document(active_root))

    local untouched = Flow.merge(latest, active, active:journal(), active._next_id)
    local merged_result = untouched.root.actions[1].results[1]
    assert.is_true(merged_result.visited)
    assert.equals("disk.symbol", merged_result.location.symbol)
    assert.equals("method", merged_result.location.symbol_kind)

    local anchor = query_anchor("lua/auth.lua", 8, 9, 17, "function enriched()")
    assert.is_true(active:apply_symbol(active_result.id, "enriched.symbol", "function", anchor))
    local touched = Flow.merge(latest, active, active:journal(), active._next_id)
    assert.equals(1, #touched.root.actions[1].results)
    local touched_result = touched.root.actions[1].results[1]
    assert.equals(active_result.id, touched_result.id)
    assert.equals("enriched.symbol", touched_result.location.symbol)
    assert.equals("function", touched_result.location.symbol_kind)
    assert.same(anchor, touched_result.location.query_anchor)
    assert.is_true(touched_result.visited)
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
      { "usages", "implementations", "definition" },
      vim.tbl_map(function(action)
        return action.label
      end, merged.root.actions)
    )
    assert.equals(active.root.id, merged.root.id)
  end)

  it("merges and remaps relationship targets without losing stable order", function()
    local latest_root = location_node(1, "lua/main.lua", 0, "main")
    local latest_a = location_node(3, "lua/a.lua", 1, "a")
    local latest_b = location_node(4, "lua/b.lua", 2, "b")
    latest_root.actions = {
      action_node(2, "textDocument/implementation", "implementations", { latest_a, latest_b }),
    }
    local latest = document(latest_root)

    local active_root = location_node(11, "lua/main.lua", 0, "main")
    local active_a = location_node(13, "lua/a.lua", 1, "a")
    local active_action = action_node(12, "textDocument/implementation", "implementations", { active_a })
    active_action.target_ids = { active_a.id }
    active_action.query_status = "partial"
    active_root.actions = { active_action }
    local active = load(document(active_root))

    local merged = Flow.merge(latest, active, active:journal(), active._next_id)
    local action = merged.root.actions[1]
    assert.equals(active_a.id, action.results[1].id)
    assert.equals("lua/b.lua", action.results[2].location.locator.path)
    assert.same({ active_a.id, action.results[2].id }, action.target_ids)
    assert.equals("partial", action.query_status)
  end)

  it("preserves authoritative replacement order and clears through save merge", function()
    local latest_root = location_node(1, "lua/main.lua", 0, "main")
    local first = location_node(3, "lua/first.lua", 1, "first")
    local second = location_node(4, "lua/second.lua", 2, "second")
    latest_root.actions = {
      action_node(2, "callHierarchy/outgoingCalls", "calls", { first, second }),
    }
    local latest = document(latest_root)
    local active = load(latest)

    active:commit_navigation({
      origin_node_id = active.root.id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { vim.deepcopy(second.location), vim.deepcopy(first.location) },
      query_status = "complete",
      replace_targets = true,
    })
    local reordered = Flow.merge(latest, active, active:journal(), active._next_id)
    assert.same({ second.id, first.id }, reordered.root.actions[1].target_ids)
    assert.equals("complete", reordered.root.actions[1].query_status)

    active:commit_navigation({
      origin_node_id = active.root.id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = {},
      query_status = "complete",
      replace_targets = true,
    })
    local cleared = Flow.merge(latest, active, active:journal(), active._next_id)
    assert.same({}, cleared.root.actions[1].target_ids)
    assert.equals(2, #cleared.root.actions[1].results)
  end)

  it("keeps explicit unlink removals while merging unrelated disk targets", function()
    local active_root = location_node(1, "lua/main.lua", 0, "main")
    local active_first = location_node(3, "lua/first.lua", 1, "first")
    local active_second = location_node(4, "lua/second.lua", 2, "second")
    active_root.actions = {
      action_node(2, "callHierarchy/outgoingCalls", "calls", { active_first, active_second }),
    }
    local active = load(document(active_root))
    assert.is_true(active:unlink_target(active.root.actions[1].id, active_second.id))

    local latest_root = location_node(1, "lua/main.lua", 0, "main")
    local latest_first = location_node(3, "lua/first.lua", 1, "first")
    local latest_second = location_node(4, "lua/second.lua", 2, "second")
    local latest_third = location_node(5, "lua/third.lua", 3, "third")
    latest_root.actions = {
      action_node(2, "callHierarchy/outgoingCalls", "calls", {
        latest_first,
        latest_second,
        latest_third,
      }),
    }

    local merged = Flow.merge(document(latest_root), active, active:journal(), active._next_id)
    local action = merged.root.actions[1]
    assert.same({ active_first.id, latest_third.id }, action.target_ids)
    assert.same(
      { active_first.id, active_second.id, latest_third.id },
      vim.tbl_map(function(result)
        return result.id
      end, action.results)
    )
  end)

  it("globally canonicalizes concurrent discoveries and remaps all links and current", function()
    local shared_anchor = {
      locator = { kind = "project", path = "lua/active_caller.lua" },
      range = {
        start = { line = 4, character = 2 },
        ["end"] = { line = 4, character = 8 },
      },
      line_text = "active_call()",
    }
    local latest_root = location_node(1, "lua/main.lua", 0, "main")
    local latest_shared = location_node(3, "lua/shared.lua", 1, "shared", "disk context")
    latest_shared.location.query_anchor = vim.deepcopy(shared_anchor)
    latest_shared.note = "disk note"
    latest_shared.actions = {
      action_node(4, "textDocument/references", "usages", {
        location_node(5, "lua/from_disk.lua", 2, "from_disk"),
      }),
    }
    latest_root.actions = {
      action_node(2, "callHierarchy/incomingCalls", "callers", { latest_shared }),
    }

    local active_root = location_node(11, "lua/main.lua", 0, "main")
    local active_shared = location_node(13, "lua/shared.lua", 1, "shared", "old active context")
    active_shared.location.query_anchor = vim.deepcopy(shared_anchor)
    active_shared.actions = {
      action_node(14, "textDocument/implementation", "implementations", {
        location_node(15, "lua/from_active.lua", 3, "from_active"),
      }),
    }
    active_root.actions = {
      action_node(12, "callHierarchy/outgoingCalls", "calls", { active_shared }),
    }
    local active = load(document(active_root))
    local active_update = Fixtures.location("lua/shared.lua", 1, "shared", "active context")
    active_update.query_anchor = vim.deepcopy(shared_anchor)
    active:commit_navigation({
      origin_node_id = active.root.id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { active_update },
    })
    assert.is_true(active:set_note(active_shared.id, "active note"))
    assert.is_true(active:set_current(active_shared.id))

    local merged = Flow.merge(document(latest_root), active, active:journal(), active._next_id)
    local merged_flow = load(merged)
    local incoming = assert(merged_flow:action_for(merged_flow.root.id, "callHierarchy/incomingCalls"))
    local outgoing = assert(merged_flow:action_for(merged_flow.root.id, "callHierarchy/outgoingCalls"))
    assert.same(incoming.target_ids, outgoing.target_ids)
    assert.equals(1, #incoming.target_ids)

    local canonical_id = incoming.target_ids[1]
    local canonical = assert(merged_flow:location(canonical_id))
    assert.equals(canonical_id, merged.current_node_id)
    assert.equals("active note", canonical.note)
    assert.equals("active context", canonical.location.context)
    assert.same(active_update.query_anchor, canonical.location.query_anchor)
    assert.is_table(merged_flow:action_for(canonical_id, "textDocument/references"))
    assert.is_table(merged_flow:action_for(canonical_id, "textDocument/implementation"))

    local shared_locations = 0
    for _, node in ipairs(merged_flow:dfs()) do
      if node.kind == "location" and node.location.locator.path == "lua/shared.lua" then
        shared_locations = shared_locations + 1
      end
    end
    assert.equals(1, shared_locations)
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
    assert.same({ imported.results[1].id }, imported.target_ids)
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
    assert.same({}, flow.root.actions[1].target_ids)
    assert.equals("complete", flow.root.actions[1].query_status)
    assert.is_false(flow:is_dirty())
  end)

  it("infers relationship fields when loading legacy nested actions", function()
    local result = location_node(3, "lua/auth.lua", 8, "auth")
    local root = location_node(1, "lua/main.lua", 0, "main")
    root.actions = { action_node(2, "textDocument/definition", "definition", { result }) }

    local flow = load(document(root))
    local action = flow.root.actions[1]
    assert.same({ result.id }, action.target_ids)
    assert.equals("complete", action.query_status)
    assert.is_false(flow:is_dirty())
  end)
end)
