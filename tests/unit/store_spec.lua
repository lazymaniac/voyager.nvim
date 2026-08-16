local FakeFS = require("tests.helpers.fake_fs")
local Fixtures = require("tests.helpers.flow")
local Flow = require("voyager.flow")
local Locator = require("voyager.locator")
local Schema = require("voyager.schema")
local Store = require("voyager.store")

local function new_store(fs, schema, project_root)
  local runtime = fs:runtime()
  return Store.new({
    runtime = runtime,
    schema = schema or Schema,
    locator = Locator.new(runtime, project_root or "/project"),
    flow = Flow,
  })
end

local function active_with_branch(path)
  local flow = Fixtures.new_flow()
  flow:commit_navigation({
    origin_node_id = flow.root.id,
    method = "textDocument/implementation",
    label = "implementations",
    locations = { Fixtures.location(path, 2, "Store.save") },
  })
  return flow
end

local function result_paths(action)
  return vim.tbl_map(function(node)
    return node.location.locator.path
  end, action.results)
end

local function encoded_entry(path, symbol, updated_at)
  local document = Fixtures.document()
  document.root.location.locator.path = path
  document.root.location.symbol = symbol
  document.root_key = Locator.root_key(document.root.location)
  document.name = Locator.flow_name(document.root.location)
  document.flow_id = Locator.flow_id(document.root.location, 8)
  document.updated_at = updated_at
  return "/project/.voyager/flows/" .. document.flow_id .. ".json", Schema.encode(document)
end

local function released_v1_json(document)
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
  return vim.json.encode(legacy)
end

describe("Voyager storage", function()
  it("atomically replaces an existing document", function()
    local existing = Fixtures.document()
    local path = "/project/.voyager/flows/" .. existing.flow_id .. ".json"
    local fs = FakeFS.new({
      directories = { "/project", "/project/.git", "/project/.voyager/flows" },
      files = { [path] = Schema.encode(existing) },
      pid = 4321,
      nonces = { "01234567" },
    })
    local store = new_store(fs)
    local active_flow = active_with_branch("lua/mysql.lua")

    local saved, err = store:save(active_flow)
    assert.is_nil(err)
    assert.equals(4, saved.revision)
    assert.same({ "write", "fsync", "close", "rename" }, fs:operation_names())
    assert.equals(Schema.encode(saved), fs.files[store:path_for(saved)])
  end)

  it("chooses the fixed project root precedence", function()
    local cases = {
      {
        name = "deepest containing LSP root",
        file = "/repo/apps/api/lua/main.lua",
        clients = { { config = { root_dir = "/repo" } }, { config = { root_dir = "/repo/apps/api" } } },
        git_root = "/repo",
        cwd = "/repo",
        expected = "/repo/apps/api",
      },
      {
        name = "nearest git ancestor",
        file = "/repo/lua/main.lua",
        clients = {},
        git_root = "/repo",
        cwd = "/outside",
        expected = "/repo",
      },
      {
        name = "containing cwd",
        file = "/repo/lua/main.lua",
        clients = {},
        git_root = nil,
        cwd = "/repo",
        expected = "/repo",
      },
      {
        name = "file parent fallback",
        file = "/repo/lua/main.lua",
        clients = {},
        git_root = nil,
        cwd = "/outside",
        expected = "/repo/lua",
      },
      {
        name = "literal environment syntax in LSP root",
        file = "/repo/$HOME/lua/main.lua",
        clients = { { config = { root_dir = "/repo/$HOME" } } },
        git_root = "/repo",
        cwd = "/repo",
        expected = "/repo/$HOME",
      },
      {
        name = "filesystem root LSP workspace falls back to the containing cwd",
        file = "/repo/lua/main.lua",
        clients = { { config = { root_dir = "/" } } },
        cwd = "/repo",
        expected = "/repo",
      },
      {
        name = "filesystem-wide discovery falls back to the file directory",
        file = "/repo/lua/main.lua",
        clients = { { config = { root_dir = "/" } } },
        git_root = "/",
        cwd = "/",
        expected = "/repo/lua",
      },
    }

    for _, case in ipairs(cases) do
      local fs = FakeFS.new({ files = { [case.file] = "return true\n" } })
      local runtime = fs:runtime()
      runtime.buffer_name = function()
        return case.file
      end
      runtime.find_root = function()
        return case.git_root
      end
      local store = Store.new({ runtime = runtime, schema = Schema, locator = Locator, flow = Flow })
      assert.equals(case.expected, store:project_root(3, case.clients, case.cwd), case.name)
    end
  end)

  it("uses only the fixed flows directory and escalates hash collisions", function()
    local fs = FakeFS.new({ directories = { "/project/.voyager/flows" } })
    local flow = Fixtures.document()
    local collision_schema = vim.tbl_extend("force", Schema, {
      decode = function(text)
        if text == "collision-8" then
          return { root_key = flow.root_key:sub(1, 8) .. string.rep("b", 56) }
        elseif text == "collision-16" then
          return { root_key = flow.root_key:sub(1, 16) .. string.rep("c", 48) }
        end
        return Schema.decode(text)
      end,
    })
    local store = new_store(fs, collision_schema)
    assert.equals("/project/.voyager/flows/" .. flow.flow_id .. ".json", store:path_for(flow))
    assert.equals("/.voyager/flows/" .. flow.flow_id .. ".json", new_store(fs, nil, "/"):path_for(flow))

    local path8 = store:path_for(flow)
    fs.files[path8] = "collision-8"
    local path16 = store:path_for(flow)
    assert.matches("%-" .. flow.root_key:sub(1, 16) .. "%.json$", path16)

    fs.files[path16] = "collision-16"
    assert.matches("%-" .. flow.root_key .. "%.json$", store:path_for(flow))
  end)

  it("refuses to save past an unreadable document at the expected flow path", function()
    local flow = Fixtures.new_flow()
    local path = "/project/.voyager/flows/" .. flow.flow_id .. ".json"
    for _, content in ipairs({
      "{not-json}\n",
      (Schema.encode(Fixtures.document()):gsub('"schema_version": 2', '"schema_version": 3', 1)),
    }) do
      local fs = FakeFS.new({
        directories = { "/project/.voyager/flows" },
        files = { [path] = content },
      })
      local store = new_store(fs)

      local resolved, path_error = store:path_for(flow)
      assert.is_nil(resolved)
      assert.matches("schema v2", path_error, nil, true)
      local saved, save_error = store:save(flow)
      assert.is_nil(saved)
      assert.matches("schema v2", save_error, nil, true)
      assert.same({ [path] = content }, fs.files)
      assert.same({}, fs:operation_names())
    end
  end)

  it("returns an empty list for a missing directory and sorts valid entries deterministically", function()
    local empty_entries, empty_warnings = new_store(FakeFS.new()):list("/project")
    assert.same({}, empty_entries)
    assert.same({}, empty_warnings)

    local files = { ["/project/.voyager/flows/corrupt.json"] = "{not-json}\n" }
    for _, entry in ipairs({
      { "lua/zeta.lua", "zeta", "2026-08-01T18:00:00Z" },
      { "lua/b.lua", "alpha", "2026-08-01T19:00:00Z" },
      { "lua/a.lua", "alpha", "2026-08-01T19:00:00Z" },
    }) do
      local path, encoded = encoded_entry(unpack(entry))
      files[path] = encoded
    end
    local fs = FakeFS.new({ directories = { "/project/.voyager/flows" }, files = files })
    local entries, warnings = new_store(fs):list("/project")
    assert.same(
      { "lua/a.lua", "lua/b.lua", "lua/zeta.lua" },
      vim.tbl_map(function(entry)
        return entry.display_path
      end, entries)
    )
    assert.equals(1, #warnings)
    assert.matches("corrupt.json", warnings[1], nil, true)
  end)

  it("re-reads and recursively merges the latest completed sequential save", function()
    local fs = FakeFS.new({ directories = { "/project/.voyager/flows" } })
    local store = new_store(fs)
    local first = active_with_branch("lua/mysql.lua")
    local second = active_with_branch("lua/memory.lua")
    assert.equals(1, assert(store:save(first)).revision)
    local merged = assert(store:save(second))

    assert.equals(2, merged.revision)
    assert.same({ "lua/mysql.lua", "lua/memory.lua" }, result_paths(merged.root.actions[1]))
  end)

  it("never persists transient stale metadata", function()
    local fs = FakeFS.new({ directories = { "/project/.voyager/flows" } })
    local store = new_store(fs)
    local flow = active_with_branch("lua/mysql.lua")
    local result = flow.root.actions[1].results[1]
    flow.root.stale = false
    result.stale = true
    result.stale_reason = "file changed"

    local saved = assert(store:save(flow))

    assert.is_nil(saved.root.stale)
    assert.is_nil(saved.root.actions[1].results[1].stale)
    assert.is_nil(saved.root.actions[1].results[1].stale_reason)
    assert.same(saved, Schema.decode(fs.files[store:path_for(saved)]))
  end)

  it("loops until a short write has persisted every byte", function()
    local fs = FakeFS.new({ directories = { "/project/.voyager/flows" } })
    fs:set_short_write(3)
    local store = new_store(fs)
    local saved = assert(store:save(active_with_branch("lua/mysql.lua")))
    assert.equals(Schema.encode(saved), fs.files[store:path_for(saved)])
    assert.is_true(vim.tbl_count(vim.tbl_filter(function(name)
      return name == "write"
    end, fs:operation_names())) > 1)
  end)

  it("cleans its temp file and preserves disk and journal on every write-stage failure", function()
    for _, operation in ipairs({ "fs_open", "fs_write", "fs_fsync", "fs_close", "fs_rename" }) do
      local existing = Schema.encode(Fixtures.document())
      local path = "/project/.voyager/flows/" .. Fixtures.document().flow_id .. ".json"
      local fs = FakeFS.new({
        directories = { "/project/.voyager/flows" },
        files = { [path] = existing },
      })
      fs:fail_next(operation, "injected " .. operation)
      local active = active_with_branch("lua/mysql.lua")
      local before = active:journal()
      local saved, err = new_store(fs):save(active)

      assert.is_nil(saved, operation)
      assert.matches("injected " .. operation, err, nil, true)
      assert.equals(existing, fs.files[path])
      assert.same({}, fs:temp_paths())
      assert.same(before, active:journal())
      assert.is_true(active:is_dirty())
    end
  end)

  it("loads a released v1 flow and rewrites its canonical graph as v2 on save", function()
    local document = Fixtures.document()
    local shared = Fixtures.location("lua/shared.lua", 4, "shared")
    shared.identity = nil
    local first = {
      id = "loc-00000000000000000000000000000003",
      kind = "location",
      location = vim.deepcopy(shared),
      actions = {},
    }
    local duplicate = vim.deepcopy(first)
    duplicate.id = "loc-00000000000000000000000000000005"
    document.root.actions = {
      {
        id = "action-00000000000000000000000000000002",
        kind = "action",
        method = "textDocument/definition",
        label = "definition",
        collapsed = false,
        target_ids = { first.id },
        query_status = "complete",
        results = { first },
      },
      {
        id = "action-00000000000000000000000000000004",
        kind = "action",
        method = "textDocument/references",
        label = "usages",
        collapsed = false,
        target_ids = { duplicate.id },
        query_status = "complete",
        results = { duplicate },
      },
    }
    document.current_node_id = duplicate.id

    local path = "/project/.voyager/flows/" .. document.flow_id .. ".json"
    local fs = FakeFS.new({
      directories = { "/project/.voyager/flows" },
      files = { [path] = released_v1_json(document) },
    })
    local store = new_store(fs)
    local flow, load_error = store:load(path, "/project")

    assert.is_nil(load_error)
    assert.equals(2, flow.schema_version)
    assert.equals(first.id, flow.current_node_id)
    assert.same({ first.id }, flow.root.actions[1].target_ids)
    assert.same({ first.id }, flow.root.actions[2].target_ids)
    assert.same({}, flow.root.actions[2].results)
    assert.equals(path, store:path_for(flow))

    local saved, save_error = store:save(flow)
    assert.is_nil(save_error)
    assert.equals(2, saved.schema_version)
    assert.equals(4, saved.revision)
    assert.is_truthy(fs.files[path]:find('"schema_version": 2', 1, true))
    assert.same(saved, Schema.decode(fs.files[path]))
  end)

  it("loads a fresh clean flow and recalculates transient stale state", function()
    local document = Fixtures.document()
    local path = "/project/.voyager/flows/" .. document.flow_id .. ".json"
    local encoded = Schema.encode(document)
    local fs = FakeFS.new({
      directories = { "/project/.voyager/flows" },
      files = {
        [path] = encoded,
        ["/project/lua/main.lua"] = "main()\n",
      },
    })

    local flow, err = new_store(fs):load(path, "/project")
    assert.is_nil(err)
    assert.equals(document.revision, flow.revision)
    assert.is_false(flow:is_dirty())
    assert.is_false(flow.root.stale)
    assert.is_nil(flow.root.location.stale)
    assert.equals(encoded, fs.files[path])
  end)
end)
