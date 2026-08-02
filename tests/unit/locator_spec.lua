local Locator = require("voyager.locator")
local Buffer = require("tests.helpers.buffer")

describe("Voyager locators", function()
  it("converts client positions to UTF-8 byte columns", function()
    local lines = { "a😀b" }
    assert.same({
      start = { line = 0, character = 1 },
      ["end"] = { line = 0, character = 5 },
    }, Locator.canonical_range(lines, {
      start = { line = 0, character = 1 },
      ["end"] = { line = 0, character = 3 },
    }, "utf-16"))
  end)

  it("uses tagged canonical keys", function()
    assert.equals('["project","lua/auth.lua"]', Locator.locator_key({ kind = "project", path = "lua/auth.lua" }))
    assert.equals('["uri","jdt://contents/Foo.class"]', Locator.locator_key({
      kind = "uri",
      uri = "jdt://contents/Foo.class",
    }))
  end)

  it("reproduces the approved root hash and name", function()
    local root = {
      locator = { kind = "project", path = "lua/auth.lua" },
      range = { start = { line = 42, character = 0 }, ["end"] = { line = 42, character = 9 } },
      symbol = "authorize",
    }
    assert.equals("d70ea46c382e0db859f48f1d97a83658e86c8751baad3d0830ef8f04b461cccf", Locator.root_key(root))
    assert.equals("authorize", Locator.flow_name(root))
    assert.equals("authorize-d70ea46c", Locator.flow_id(root, 8))
  end)

  it("uses filename and one-based line for anonymous roots", function()
    local root = {
      locator = { kind = "project", path = "lua/auth.lua" },
      range = { start = { line = 4, character = 0 }, ["end"] = { line = 4, character = 0 } },
      symbol = "<anonymous>",
    }
    assert.equals("auth.lua:5", Locator.flow_name(root))
    assert.matches("^auth%-lua%-5%-[0-9a-f]+$", Locator.flow_id(root, 8))
  end)

  it("rejects malformed, clamped, and reversed protocol ranges", function()
    local lines = { "a😀b", "tail" }
    for _, range in ipairs({
      { start = { line = 0, character = -1 }, ["end"] = { line = 0, character = 0 } },
      { start = { line = 0, character = 10 }, ["end"] = { line = 0, character = 10 } },
      { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 3 } },
      { start = { line = 1, character = 0 }, ["end"] = { line = 0, character = 0 } },
    }) do
      local converted, reason = Locator.canonical_range(lines, range, "utf-16")
      assert.is_nil(converted)
      assert.is_string(reason)
    end
  end)

  it("prefers an exact loaded named-unsaved buffer over disk", function()
    local env = Buffer.new({
      files = { ["/project/lua/new.lua"] = { "disk" } },
      buffers = { { id = 17, name = "/project/lua/new.lua", loaded = true, lines = { "unsaved" } } },
    })
    local locator = Locator.new(env.runtime, "/project", nil)
    assert.same({ "unsaved" }, locator:source({ kind = "project", path = "lua/new.lua" }))
    assert.same({ "find_buffer:/project/lua/new.lua", "get_buffer_lines:17" }, env.runtime.calls)
  end)

  it("normalizes file locators and reads an unloaded target without adding a buffer", function()
    local env = Buffer.new({ files = { ["/project/lua/auth.lua"] = { "return true" } } })
    local locator = Locator.new(env.runtime, "/project/./", nil)
    assert.same({ kind = "project", path = "lua/auth.lua" }, locator:from_uri("file:///project/lua/../lua/auth.lua"))
    assert.same({ "return true" }, locator:source({ kind = "project", path = "lua\\auth.lua" }))
    assert.same({}, env.buffers)
  end)

  it("requires an exact loaded non-file URI or a valid resolver result", function()
    local env = Buffer.new({
      buffers = {
        { id = 21, name = "jdt://contents/Foo.class", loaded = true, lines = { "class Foo" } },
        { id = 22, name = "resolver://backing", loaded = true, lines = { "class Bar" } },
      },
    })
    local locator = Locator.new(env.runtime, "/project", function(uri)
      return uri == "jdt://contents/Bar.class" and 22 or nil
    end)
    assert.same({ "class Foo" }, locator:source({ kind = "uri", uri = "jdt://contents/Foo.class" }))
    assert.same({ "class Bar" }, locator:source({ kind = "uri", uri = "jdt://contents/Bar.class" }))
    local lines, reason = locator:source({ kind = "uri", uri = "jdt://contents/Missing.class" })
    assert.is_nil(lines)
    assert.equals("non-file URI has no loaded source", reason)
  end)

  it("checks staleness and opens file targets only on demand", function()
    local env = Buffer.new({ files = { ["/project/lua/auth.lua"] = { "abc" } } })
    local locator = Locator.new(env.runtime, "/project", nil)
    local location = {
      locator = { kind = "project", path = "lua/auth.lua" },
      range = { start = { line = 0, character = 1 }, ["end"] = { line = 0, character = 3 } },
      symbol = "bc",
    }
    assert.is_false(locator:is_stale(location))
    assert.same({ bufnr = 1, row = 1, col = 1 }, locator:open_target(location))
    assert.is_true(env.buffers[1].listed)
    location.range["end"].character = 4
    assert.is_true(locator:is_stale(location))
  end)

  it("uses deterministic slug and node-ID inputs", function()
    local next_id = Locator.id_factory("authorize-d70ea46c", string.rep("\1", 16), 40, function(input)
      return vim.fn.sha256(input)
    end)
    assert.matches("^loc%-[0-9a-f][0-9a-f]+$", next_id("location"))
    assert.matches("^action%-[0-9a-f][0-9a-f]+$", next_id("action"))
    assert.equals("a-b-c", Locator.slug(" A😀B/Ç "))
  end)
end)
