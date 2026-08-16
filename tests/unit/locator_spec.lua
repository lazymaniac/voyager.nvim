local Locator = require("voyager.locator")
local Buffer = require("tests.helpers.buffer")

describe("Voyager locators", function()
  it("converts client positions to UTF-8 byte columns", function()
    local lines = { "a😀b" }
    assert.same(
      {
        start = { line = 0, character = 1 },
        ["end"] = { line = 0, character = 5 },
      },
      Locator.canonical_range(lines, {
        start = { line = 0, character = 1 },
        ["end"] = { line = 0, character = 3 },
      }, "utf-16")
    )
  end)

  it("uses tagged canonical keys", function()
    assert.equals('["project","lua/auth.lua"]', Locator.locator_key({ kind = "project", path = "lua/auth.lua" }))
    assert.equals(
      '["uri","jdt://contents/Foo.class"]',
      Locator.locator_key({
        kind = "uri",
        uri = "jdt://contents/Foo.class",
      })
    )
  end)

  it("includes the semantic query anchor in location identity", function()
    local location = {
      locator = { kind = "project", path = "lua/main.lua" },
      range = { start = { line = 3, character = 4 }, ["end"] = { line = 3, character = 8 } },
    }
    local unanchored = Locator.location_key(location)
    local first = vim.deepcopy(location)
    first.query_anchor = {
      locator = { kind = "project", path = "lua/caller.lua" },
      range = { start = { line = 1, character = 0 }, ["end"] = { line = 1, character = 6 } },
      line_text = "caller()",
    }
    local second = vim.deepcopy(first)
    second.query_anchor.locator.path = "lua/callee.lua"

    assert.not_equals(unanchored, Locator.location_key(first))
    assert.not_equals(Locator.location_key(first), Locator.location_key(second))
    first.query_anchor.line_text = "changed metadata"
    assert.equals(
      Locator.location_key(first),
      Locator.location_key(vim.tbl_extend("force", vim.deepcopy(first), {
        query_anchor = vim.tbl_extend("force", vim.deepcopy(first.query_anchor), { line_text = "other metadata" }),
      }))
    )
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

  it("treats every absolute file as project-local when the project root is slash", function()
    local env = Buffer.new({ files = { ["/project/lua/auth.lua"] = { "return true" } } })
    local locator = Locator.new(env.runtime, "/", nil)

    assert.same({ kind = "project", path = "project/lua/auth.lua" }, locator:from_uri("file:///project/lua/auth.lua"))
    assert.is_true(locator:is_project_uri("file:///project/lua/auth.lua"))
    assert.same({ "return true" }, locator:source({ kind = "project", path = "project/lua/auth.lua" }))
  end)

  it("uses real paths for project membership and semantic subjects", function()
    local env = Buffer.new({})
    local aliases = {
      ["/workspace-link"] = "/real/project",
      ["/workspace-link/lua/inside.lua"] = "/real/project/lua/inside.lua",
      ["/real/project/lua/vendor.lua"] = "/opt/vendor/vendor.lua",
      ["/outside/inside.lua"] = "/real/project/lua/inside.lua",
    }
    env.runtime.fs_realpath = function(path)
      local normalized = vim.fs.normalize(path:gsub("\\", "/"), { expand_env = false })
      return aliases[normalized] or normalized
    end
    local locator = Locator.new(env.runtime, "/workspace-link", nil)

    assert.is_true(locator:is_project_uri("file:///workspace-link/lua/inside.lua"))
    assert.is_true(locator:is_project_uri("file:///outside/inside.lua"))
    assert.is_false(locator:is_project_uri("file:///real/project/lua/vendor.lua"))
    assert.is_false(locator:is_project_uri("jdt://contents/Vendor.class"))
    assert.is_false(locator:is_project_locator({ kind = "project", path = "lua/vendor.lua" }))

    local location = {
      locator = { kind = "project", path = "lua/inside.lua" },
      range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 1 } },
      query_anchor = {
        locator = { kind = "absolute", path = "/opt/vendor/vendor.lua" },
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 1 } },
      },
    }
    assert.is_false(locator:is_project_location(location))
    location.query_anchor.locator = { kind = "project", path = "lua/inside.lua" }
    assert.is_true(locator:is_project_location(location))
    location.locator = { kind = "absolute", path = "/opt/vendor/callsite.lua" }
    assert.is_false(locator:is_project_location(location))
  end)

  it("excludes dependency trees that live inside the project root", function()
    local env = Buffer.new({})
    local locator = Locator.new(env.runtime, "/project", nil)

    assert.is_true(locator:is_project_uri("file:///project/lua/service.lua"))
    for _, path in ipairs({
      "node_modules/pkg/index.js",
      ".venv/lib/site-packages/pkg.py",
      "vendor/pkg/source.go",
      "third_party/pkg/source.cc",
      ".deps/tool.lua",
    }) do
      assert.is_false(locator:is_project_uri("file:///project/" .. path), path)
    end
  end)

  it("keeps environment syntax literal in project-relative locators", function()
    local env = Buffer.new({
      files = {
        ["/project/lua/$HOME.lua"] = { "literal environment name" },
        ["/project/~/notes.lua"] = { "literal tilde directory" },
      },
    })
    local locator = Locator.new(env.runtime, "/project", nil)

    assert.same({ "literal environment name" }, locator:source({ kind = "project", path = "lua/$HOME.lua" }))
    assert.same({ "literal tilde directory" }, locator:source({ kind = "project", path = "~/notes.lua" }))
  end)

  it("keeps environment syntax literal in project roots and absolute locators", function()
    local env = Buffer.new({
      files = {
        ["/project/$HOME/lua/main.lua"] = { "literal project root" },
        ["/external/$HOME.lua"] = { "literal absolute target" },
      },
    })
    local locator = Locator.new(env.runtime, "/project/$HOME", nil)

    assert.same({ kind = "project", path = "lua/main.lua" }, locator:from_uri("file:///project/$HOME/lua/main.lua"))
    assert.same({ kind = "absolute", path = "/external/$HOME.lua" }, locator:from_uri("file:///external/$HOME.lua"))
    assert.same({ "literal absolute target" }, locator:source({ kind = "absolute", path = "/external/$HOME.lua" }))
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

  it("keeps files loaded only for a background query out of the buffer list", function()
    local env = Buffer.new({ files = { ["/project/lua/auth.lua"] = { "abc" } } })
    local locator = Locator.new(env.runtime, "/project", nil)
    local location = {
      locator = { kind = "project", path = "lua/auth.lua" },
      range = { start = { line = 0, character = 1 }, ["end"] = { line = 0, character = 3 } },
      symbol = "bc",
    }

    assert.same({ bufnr = 1, row = 1, col = 1 }, locator:open_target(location, { list = false }))
    assert.is_false(env.buffers[1].listed)

    -- Once the buffer already exists, querying it must preserve its state.
    env.buffers[1].listed = true
    assert.same({ bufnr = 1, row = 1, col = 1 }, locator:open_target(location, { list = false }))
    assert.is_true(env.buffers[1].listed)
  end)

  it("preserves a user-owned unloaded buffer's listed state for a background query", function()
    local env = Buffer.new({
      files = { ["/project/lua/auth.lua"] = { "abc" } },
      buffers = {
        {
          id = 7,
          name = "/project/lua/auth.lua",
          valid = true,
          loaded = false,
          listed = true,
        },
      },
    })
    local locator = Locator.new(env.runtime, "/project", nil)
    local location = {
      locator = { kind = "project", path = "lua/auth.lua" },
      range = { start = { line = 0, character = 1 }, ["end"] = { line = 0, character = 3 } },
      symbol = "bc",
    }

    assert.same({ bufnr = 7, row = 1, col = 1 }, locator:open_target(location, { list = false }))
    assert.is_true(env.buffers[1].loaded)
    assert.is_true(env.buffers[1].listed)
    assert.is_false(vim.tbl_contains(env.runtime.calls, "set_buffer_listed:7"))
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
