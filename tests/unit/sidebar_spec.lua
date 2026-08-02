local Fixtures = require("tests.helpers.flow")
local Locator = require("voyager.locator")
local Sidebar = require("voyager.sidebar")

local function row_for(rows, kind, owner_id)
  for index, row in ipairs(rows) do
    if row.kind == kind and row.owner_id == owner_id then
      return row, index
    end
  end
end

describe("Voyager sidebar projection", function()
  it("projects the flow in stable depth-first order", function()
    local flow = Fixtures.branched_flow()
    local rows, header = Sidebar.project(flow, 42, { dirty = true, request_count = 2 })
    assert.same({
      { kind = "location", owner_id = flow.root.id },
      { kind = "action", owner_id = flow.root.actions[1].id },
      { kind = "location", owner_id = flow.root.actions[1].results[1].id },
      { kind = "note", owner_id = flow.root.actions[1].results[1].id },
      { kind = "location", owner_id = flow.root.actions[1].results[2].id },
    }, vim.tbl_map(function(row)
      return { kind = row.kind, owner_id = row.owner_id }
    end, rows))
    assert.matches("%*", header)
    assert.matches("2 requests", header)
  end)

  it("keeps duplicate display text distinct by kind and owner ID", function()
    local flow = Fixtures.branched_flow()
    local first = flow.root.actions[1].results[1]
    local second = flow.root.actions[1].results[2]
    second.location = vim.deepcopy(first.location)
    local rows = Sidebar.project(flow, 42, { dirty = false, request_count = 0 })
    local first_row = assert(row_for(rows, "location", first.id))
    local second_row, second_index = row_for(rows, "location", second.id)

    assert.equals(first_row.text, second_row.text)
    assert.equals(second_index, Sidebar.selection_index(rows, "location", second.id))
  end)

  it("marks current, stale, empty, and collapsed descendant states", function()
    local flow = Fixtures.branched_flow()
    local implementation = flow.root.actions[1]
    local mysql = implementation.results[1]
    local nested = flow:commit_navigation({
      origin_node_id = mysql.id,
      method = "textDocument/references",
      label = "references",
      locations = { Fixtures.location("lua/auth.lua", 8, "AuthService.login") },
    })
    local auth_id = nested.node_id_by_identity[Fixtures.identity("lua/auth.lua", 8)]
    assert.is_true(flow:set_current(auth_id))
    local empty = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/references",
      label = "references",
      locations = {},
    })
    implementation.results[2].stale = true

    local expanded = Sidebar.project(flow, 42, { dirty = true, request_count = 0 })
    assert.equals("current", row_for(expanded, "location", auth_id).marker)
    assert.equals("stale", row_for(expanded, "location", implementation.results[2].id).marker)
    assert.matches("references %(0%)", row_for(expanded, "action", empty.action_id).text)

    assert.is_true(flow:toggle(implementation.id))
    local collapsed = Sidebar.project(flow, 42, { dirty = true, request_count = 0 })
    local action_row, action_index = row_for(collapsed, "action", implementation.id)
    assert.equals("descendant_current", action_row.marker)
    assert.is_nil(row_for(collapsed, "location", auth_id))
    assert.equals(action_index, Sidebar.selection_index(collapsed, "location", auth_id, implementation.id))
  end)

  it("renders project, absolute, and URI locations with one-based lines", function()
    local flow = Fixtures.new_flow()
    local project = Fixtures.location("lua/auth.lua", 2, "project")
    local absolute = Fixtures.location("unused", 3, "absolute")
    absolute.locator = { kind = "absolute", path = "/opt/vendor/auth.lua" }
    absolute.identity = Locator.location_key(absolute)
    local uri = Fixtures.location("unused", 4, "uri")
    uri.locator = { kind = "uri", uri = "jdt://contents/Auth.class" }
    uri.identity = Locator.location_key(uri)
    local commit = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/definition",
      label = "definition",
      locations = { project, absolute, uri },
    })
    local rows = Sidebar.project(flow, 80, { dirty = true, request_count = 0 })

    assert.matches("lua/auth.lua:3", row_for(rows, "location", commit.node_id_by_identity[project.identity]).text, nil, true)
    assert.matches(
      "/opt/vendor/auth.lua:4",
      row_for(rows, "location", commit.node_id_by_identity[absolute.identity]).text,
      nil,
      true
    )
    assert.matches(
      "jdt://contents/Auth.class:5",
      row_for(rows, "location", commit.node_id_by_identity[uri.identity]).text,
      nil,
      true
    )
  end)

  it("indents and display-width truncates notes", function()
    local flow = Fixtures.branched_flow()
    local owner = flow.root.actions[1].results[1]
    flow:set_note(owner.id, "important 😀 authentication path that is deliberately long")
    local rows = Sidebar.project(flow, 20, { dirty = true, request_count = 0 })
    local note = row_for(rows, "note", owner.id)

    assert.equals(3, note.depth)
    assert.matches("^%s+✎", note.text)
    assert.is_true(vim.fn.strdisplaywidth(note.text) <= 20)
    assert.matches("…$", note.text)
  end)
end)
