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
  return {
    id = node_id("action", value),
    kind = "action",
    method = method,
    label = label,
    collapsed = collapsed or false,
    results = results or {},
  }
end

describe("Voyager schema", function()
  it("round-trips canonical JSON byte-for-byte", function()
    local encoded = Schema.encode(Fixtures.document())
    assert.equals(encoded, Schema.encode(Schema.decode(encoded)))
    assert.matches('^%{%s+"schema_version": 1,', encoded)
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

  it("rejects unknown keys and semantic identity mismatches", function()
    local encoded = Schema.encode(Fixtures.document())
    assert.has_error(function()
      Schema.decode(encoded:gsub('"revision": 3', '"revision": 3, "mystery": true', 1))
    end, "schema v1: unknown key $.mystery")
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
      end, "schema v1: $.root.location.locator project locator path is not canonical")
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
    end, "schema v1: $.root.actions[2].method duplicates a sibling action method")

    local duplicate_locations = Fixtures.document()
    duplicate_locations.root.actions = {
      action_node(2, "textDocument/implementation", "implementations", {
        location_node(3, "lua/store.lua", 4, "save"),
        location_node(4, "lua/store.lua", 4, "save"),
      }),
    }
    assert.has_error(function()
      Schema.validate(duplicate_locations)
    end, "schema v1: $.root.actions[1].results[2].location duplicates a sibling location identity")
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
      end, "schema v1: $.updated_at must be a UTC RFC 3339 timestamp at second precision")
    end

    local leap_year = Fixtures.document()
    leap_year.updated_at = "2024-02-29T23:59:59Z"
    assert.has_no.errors(function()
      Schema.validate(leap_year)
    end)
  end)

  it("rejects every schema-v1 structural and semantic violation", function()
    local cases = {
      {
        "newer version",
        function(d)
          d.schema_version = 2
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
