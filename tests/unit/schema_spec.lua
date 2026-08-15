local Schema = require("voyager.schema")
local Fixtures = require("tests.helpers.flow")
local Locator = require("voyager.locator")

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
  results = results or {}
  return {
    id = node_id("action", value),
    kind = "action",
    method = method,
    label = label,
    collapsed = collapsed or false,
    target_ids = vim.tbl_map(function(result)
      return result.id
    end, results),
    query_status = "complete",
    results = results,
  }
end

local function as_released_v1(document)
  local legacy = vim.deepcopy(document)
  legacy.schema_version = 1
  local function visit(node)
    if node.kind == "action" then
      node.target_ids = nil
      node.query_status = nil
      for _, result in ipairs(node.results) do
        visit(result)
      end
      return
    end
    node.location.query_anchor = nil
    for _, action in ipairs(node.actions) do
      visit(action)
    end
  end
  visit(legacy.root)
  return legacy
end

describe("Voyager schema", function()
  it("round-trips canonical JSON byte-for-byte", function()
    local encoded = Schema.encode(Fixtures.document())
    assert.equals(encoded, Schema.encode(Schema.decode(encoded)))
    assert.matches('^%{%s+"schema_version": 2,', encoded)
    assert.matches('\n  "position_encoding": "utf%-8",', encoded)
    assert.matches("%}\n$", encoded)
  end)

  it("omits absent optional fields and rejects null", function()
    local document = Fixtures.document()
    document.root.note = nil
    document.root.location.context = nil
    local encoded = Schema.encode(document)
    assert.is_nil(encoded:match('"note"'))
    assert.is_nil(encoded:match('"context"'))
    assert.has_error(function()
      Schema.decode(encoded:gsub('"actions":', '"note": null, "actions":', 1))
    end)
  end)

  it("round-trips visited and symbol_kind and rejects wrong types", function()
    local document = Fixtures.document()
    document.root.visited = true
    document.root.location.symbol_kind = "function"
    local encoded = Schema.encode(document)
    assert.matches('"visited": true', encoded)
    assert.matches('"symbol_kind": "function"', encoded)
    local decoded = Schema.decode(encoded)
    assert.is_true(decoded.root.visited)
    assert.equals("function", decoded.root.location.symbol_kind)

    local unvisited = Fixtures.document()
    assert.is_nil(Schema.encode(unvisited):match('"visited"'))

    assert.has_error(function()
      local bad = Fixtures.document()
      bad.root.visited = "yes"
      Schema.encode(bad)
    end, "schema v2: $.root.visited must be a boolean")
    assert.has_error(function()
      local bad = Fixtures.document()
      bad.root.location.symbol_kind = ""
      Schema.encode(bad)
    end, "schema v2: $.root.location.symbol_kind must be a non-empty string")
  end)

  it("round-trips an optional call-hierarchy query anchor and accepts legacy locations", function()
    local document = Fixtures.document()
    document.root.location.query_anchor = {
      locator = { kind = "project", path = "lua/caller.lua" },
      range = {
        start = { line = 4, character = 9 },
        ["end"] = { line = 4, character = 15 },
      },
      line_text = "function caller()",
    }

    local encoded = Schema.encode(document)
    local decoded = Schema.decode(encoded)
    assert.same(document.root.location.query_anchor, decoded.root.location.query_anchor)

    local legacy = Fixtures.document()
    assert.has_no.errors(function()
      Schema.validate(legacy)
    end)
    assert.is_nil(Schema.decode(Schema.encode(legacy)).root.location.query_anchor)

    local invalid = Fixtures.document()
    invalid.root.location.query_anchor = vim.deepcopy(document.root.location.query_anchor)
    invalid.root.location.query_anchor.line_text = ""
    assert.has_error(function()
      Schema.validate(invalid)
    end, "schema v2: $.root.location.query_anchor.line_text must be a non-empty string")
  end)

  it("rejects unknown keys and semantic identity mismatches", function()
    local encoded = Schema.encode(Fixtures.document())
    assert.has_error(function()
      Schema.decode(encoded:gsub('"revision": 3', '"revision": 3, "mystery": true', 1))
    end, "schema v2: unknown key $.mystery")
  end)

  it("rejects non-canonical aliases for project locator paths", function()
    for _, path in ipairs({ "lua//main.lua", "lua/main.lua/" }) do
      local document = Fixtures.document()
      document.root.location.locator.path = path
      document.root_key = Locator.root_key(document.root.location)
      document.name = Locator.flow_name(document.root.location)
      document.flow_id = Locator.flow_id(document.root.location, 8)

      assert.has_error(function()
        Schema.validate(document)
      end, "schema v2: $.root.location.locator project locator path is not canonical")
    end

    for _, path in ipairs({ "~/notes.lua", "lua/$HOME.lua" }) do
      local document = Fixtures.document()
      document.root.location.locator.path = path
      document.root_key = Locator.root_key(document.root.location)
      document.name = Locator.flow_name(document.root.location)
      document.flow_id = Locator.flow_id(document.root.location, 8)

      assert.has_no.errors(function()
        Schema.validate(document)
      end)
    end

    local absolute = Fixtures.document()
    absolute.root.location.locator = { kind = "absolute", path = "/external/$HOME.lua" }
    absolute.root_key = Locator.root_key(absolute.root.location)
    absolute.name = Locator.flow_name(absolute.root.location)
    absolute.flow_id = Locator.flow_id(absolute.root.location, 8)
    assert.has_no.errors(function()
      Schema.validate(absolute)
    end)
  end)

  it("rejects duplicate sibling action methods and location identities", function()
    local duplicate_actions = Fixtures.document()
    duplicate_actions.root.actions = {
      action_node(2, "textDocument/definition", "definition"),
      action_node(3, "textDocument/definition", "definition"),
    }
    assert.has_error(function()
      Schema.validate(duplicate_actions)
    end, "schema v2: $.root.actions[2].method duplicates a sibling action method")

    local duplicate_locations = Fixtures.document()
    duplicate_locations.root.actions = {
      action_node(2, "textDocument/implementation", "implementations", {
        location_node(3, "lua/store.lua", 4, "save"),
        location_node(4, "lua/store.lua", 4, "save"),
      }),
    }
    assert.has_error(
      function()
        Schema.validate(duplicate_locations)
      end,
      "schema v2: $.root.actions[1].results[2].location duplicates location identity at "
        .. "$.root.actions[1].results[1].location"
    )

    local duplicate_across_actions = Fixtures.document()
    duplicate_across_actions.root.actions = {
      action_node(2, "textDocument/definition", "definition", {
        location_node(3, "lua/store.lua", 4, "save"),
      }),
      action_node(4, "textDocument/references", "usages", {
        location_node(5, "lua/store.lua", 4, "save"),
      }),
    }
    assert.has_error(
      function()
        Schema.validate(duplicate_across_actions)
      end,
      "schema v2: $.root.actions[2].results[1].location duplicates location identity at "
        .. "$.root.actions[1].results[1].location"
    )
  end)

  it("upgrades legacy actions and always encodes relationship fields", function()
    local document = Fixtures.document()
    local result = location_node(3, "lua/auth.lua", 8, "auth")
    document.root.actions = {
      action_node(2, "textDocument/definition", "definition", { result }),
    }
    local legacy = as_released_v1(document)

    local validated = Schema.validate(legacy)
    local action = validated.root.actions[1]
    assert.equals(2, validated.schema_version)
    assert.same({ result.id }, action.target_ids)
    assert.equals("complete", action.query_status)
    assert.is_nil(legacy.root.actions[1].target_ids)
    assert.is_nil(legacy.root.actions[1].query_status)

    local encoded = Schema.encode(legacy)
    assert.matches('^%{%s+"schema_version": 2,', encoded)
    assert.is_truthy(encoded:find('"target_ids": ["' .. result.id .. '"]', 1, true))
    assert.matches('"query_status": "complete"', encoded)
    local decoded = Schema.decode(encoded)
    assert.same({ result.id }, decoded.root.actions[1].target_ids)
  end)

  it("migrates released v1 duplicate identities into one canonical relationship graph", function()
    local document = Fixtures.document()
    local first = location_node(3, "lua/shared.lua", 4, "first symbol", "first context")
    local first_child = location_node(5, "lua/first_child.lua", 5, "first child")
    first.actions = {
      action_node(4, "textDocument/references", "usages", { first_child }, true),
    }

    local duplicate = location_node(7, "lua/shared.lua", 4, "second symbol", "second context")
    duplicate.note = "preserved note"
    duplicate.visited = true
    duplicate.location.symbol_kind = "method"
    local second_child = location_node(9, "lua/second_child.lua", 6, "second child")
    local implementation = location_node(11, "lua/implementation.lua", 7, "implementation")
    duplicate.actions = {
      action_node(8, "textDocument/references", "usages", { second_child }),
      action_node(10, "textDocument/implementation", "implementations", { implementation }),
    }

    document.root.actions = {
      action_node(2, "textDocument/definition", "definition", { first }),
      action_node(6, "callHierarchy/incomingCalls", "callers", { duplicate }),
    }
    document.current_node_id = duplicate.id
    local legacy = as_released_v1(document)

    local migrated = Schema.validate(legacy)
    local definition = migrated.root.actions[1]
    local callers = migrated.root.actions[2]
    local canonical = definition.results[1]

    assert.equals(2, migrated.schema_version)
    assert.equals(first.id, canonical.id)
    assert.equals(first.id, migrated.current_node_id)
    assert.same({ first.id }, definition.target_ids)
    assert.same({ first.id }, callers.target_ids)
    assert.same({}, callers.results)
    assert.equals("first symbol", canonical.location.symbol)
    assert.equals("first context", canonical.location.context)
    assert.equals("method", canonical.location.symbol_kind)
    assert.equals("preserved note", canonical.note)
    assert.is_true(canonical.visited)
    assert.equals(2, #canonical.actions)
    assert.same({ first_child.id, second_child.id }, canonical.actions[1].target_ids)
    assert.same(
      { first_child.id, second_child.id },
      vim.tbl_map(function(result)
        return result.id
      end, canonical.actions[1].results)
    )
    assert.same({ implementation.id }, canonical.actions[2].target_ids)

    local shared_count = 0
    local function visit(node)
      if node.kind == "location" and node.location.locator.path == "lua/shared.lua" then
        shared_count = shared_count + 1
      end
      local children = node.kind == "location" and node.actions or node.results
      for _, child in ipairs(children) do
        visit(child)
      end
    end
    visit(migrated.root)
    assert.equals(1, shared_count)
    assert.same(migrated, Schema.decode(Schema.encode(legacy)))
  end)

  it("validates released v1 with sibling-only identity uniqueness before migration", function()
    local document = Fixtures.document()
    document.root.actions = {
      action_node(2, "textDocument/implementation", "implementations", {
        location_node(3, "lua/store.lua", 4, "save"),
        location_node(4, "lua/store.lua", 4, "save"),
      }),
    }

    assert.has_error(function()
      Schema.validate(as_released_v1(document))
    end, "schema v1: $.root.actions[1].results[2].location duplicates a sibling location identity")
  end)

  it("accepts the internal archive carrier as unlinked storage", function()
    local document = Fixtures.document()
    local archived = location_node(3, "lua/archived.lua", 8, "archived")
    local archive = action_node(2, "voyager/archive", "archived records", { archived }, true)
    archive.target_ids = {}
    archive.query_status = "complete"
    document.root.actions = { archive }

    local validated = Schema.validate(document)
    assert.equals("voyager/archive", validated.root.actions[1].method)
    assert.same({}, validated.root.actions[1].target_ids)
    assert.equals(archived.id, validated.root.actions[1].results[1].id)
  end)

  it("accepts cross-branch targets and partial query status", function()
    local document = Fixtures.document()
    local first = location_node(3, "lua/first.lua", 1, "first")
    local second = location_node(4, "lua/second.lua", 2, "second")
    local ownership = action_node(2, "textDocument/implementation", "implementations", { first, second })
    local cross_link = action_node(5, "callHierarchy/outgoingCalls", "calls", {})
    cross_link.target_ids = { second.id, document.root.id }
    cross_link.query_status = "partial"
    first.actions = { cross_link }
    document.root.actions = { ownership }

    local validated = Schema.validate(document)
    assert.same({ second.id, document.root.id }, validated.root.actions[1].results[1].actions[1].target_ids)
    assert.equals("partial", validated.root.actions[1].results[1].actions[1].query_status)
  end)

  it("rejects duplicate, dangling, and non-location relationship targets", function()
    local function relationship_document(target_ids)
      local document = Fixtures.document()
      local action = action_node(2, "textDocument/definition", "definition", {})
      action.target_ids = target_ids
      action.query_status = "complete"
      document.root.actions = { action }
      return document
    end

    assert.has_error(function()
      Schema.validate(relationship_document({ node_id("loc", 1), node_id("loc", 1) }))
    end, "schema v2: $.root.actions[1].target_ids[2] duplicates an earlier target ID")
    assert.has_error(function()
      Schema.validate(relationship_document({ node_id("loc", 99) }))
    end, "schema v2: $.root.actions[1].target_ids[1] references a missing location")
    assert.has_error(function()
      Schema.validate(relationship_document({ node_id("action", 2) }))
    end, "schema v2: $.root.actions[1].target_ids[1] is not a canonical location ID")

    local invalid_status = relationship_document({ node_id("loc", 1) })
    invalid_status.root.actions[1].query_status = "stale"
    assert.has_error(function()
      Schema.validate(invalid_status)
    end, "schema v2: $.root.actions[1].query_status must equal complete or partial")
  end)

  it("rejects impossible RFC 3339 timestamps", function()
    for _, timestamp in ipairs({
      "2026-99-01T12:00:00Z",
      "2026-02-29T12:00:00Z",
      "2024-02-30T12:00:00Z",
      "2026-08-01T24:00:00Z",
      "2026-08-01T12:60:00Z",
      "2026-08-01T12:00:61Z",
    }) do
      local document = Fixtures.document()
      document.updated_at = timestamp

      assert.has_error(function()
        Schema.validate(document)
      end, "schema v2: $.updated_at must be a UTC RFC 3339 timestamp at second precision")
    end

    local leap_year = Fixtures.document()
    leap_year.updated_at = "2024-02-29T23:59:59Z"
    assert.has_no.errors(function()
      Schema.validate(leap_year)
    end)
  end)

  it("rejects every schema-v2 structural and semantic violation", function()
    local cases = {
      {
        "newer version",
        function(d)
          d.schema_version = 3
        end,
        "schema_version",
      },
      {
        "non-UTF-8 positions",
        function(d)
          d.position_encoding = "utf-16"
        end,
        "position_encoding",
      },
      {
        "zero revision",
        function(d)
          d.revision = 0
        end,
        "revision",
      },
      {
        "invalid timestamp",
        function(d)
          d.updated_at = "2026-08-01"
        end,
        "updated_at",
      },
      {
        "invalid node kind",
        function(d)
          d.root.kind = "result"
        end,
        "kind",
      },
      {
        "duplicate ID",
        function(d)
          d.root.actions = {
            action_node(2, "textDocument/definition", "definition", {
              vim.tbl_extend("force", location_node(2, "lua/auth.lua", 8, "auth"), { id = d.root.id }),
            }),
          }
        end,
        "duplicate",
      },
      {
        "non-alternating child",
        function(d)
          d.root.actions = { location_node(2, "lua/auth.lua", 8, "auth") }
        end,
        "action",
      },
      {
        "missing current location",
        function(d)
          d.current_node_id = node_id("loc", 99)
        end,
        "current_node_id",
      },
      {
        "null optional",
        function(d)
          d.root.note = vim.NIL
        end,
        "note",
      },
      {
        "invalid locator",
        function(d)
          d.root.location.locator.path = "../escape.lua"
        end,
        "locator",
      },
      {
        "inverted range",
        function(d)
          d.root.location.range.start.character = 5
          d.root.location.range["end"].character = 1
        end,
        "range",
      },
      {
        "wrong root key",
        function(d)
          d.root_key = string.rep("b", 64)
        end,
        "root_key",
      },
      {
        "wrong name",
        function(d)
          d.name = "not-main"
        end,
        "name",
      },
      {
        "wrong flow ID",
        function(d)
          d.flow_id = "not-main-bbbbbbbb"
        end,
        "flow_id",
      },
      {
        "unknown action method",
        function(d)
          d.root.actions = { action_node(2, "textDocument/unknown", "unknown", {}) }
        end,
        "method",
      },
    }

    for _, case in ipairs(cases) do
      local document_value = Fixtures.document()
      case[2](document_value)
      local ok, err = pcall(Schema.validate, document_value)
      assert.is_false(ok, case[1])
      assert.matches(case[3], tostring(err), nil, true)
    end
  end)
end)
