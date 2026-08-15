local Buffer = require("tests.helpers.buffer")
local FakeClient = require("tests.helpers.fake_lsp_client")
local Locator = require("voyager.locator")
local Normalize = require("voyager.lsp.normalize")

local function protocol_range(start_character, end_character, start_line, end_line)
  return {
    start = { line = start_line or 0, character = start_character },
    ["end"] = { line = end_line or start_line or 0, character = end_character },
  }
end

local function link(range)
  return {
    targetUri = "file:///project/lua/auth.lua",
    targetRange = protocol_range(0, 4),
    targetSelectionRange = range,
  }
end

local function location(range, uri)
  return {
    uri = uri or "file:///project/lua/auth.lua",
    range = range,
  }
end

local function setup(spec, resolve_uri)
  local env = Buffer.new(spec)
  local locator = Locator.new(env.runtime, "/project", resolve_uri)
  return env, locator, Normalize.new({ locator = locator })
end

local function client(id, name, encoding)
  return FakeClient.new({ id = id, name = name, offset_encoding = encoding or "utf-16" }):snapshot()
end

local function expected_failure(client_snapshot, response_index, invalid_item_count)
  return {
    kind = "normalization",
    client_id = client_snapshot.id,
    client_name = client_snapshot.name,
    response_index = response_index,
    invalid_item_count = invalid_item_count,
    message = string.format(
      "%d LSP response item%s could not be normalized",
      invalid_item_count,
      invalid_item_count == 1 and "" or "s"
    ),
  }
end

describe("Voyager LSP location normalization", function()
  it("uses a LocationLink selection range and canonical UTF-8 bytes", function()
    local _, _, normalizer = setup({ files = { ["/project/lua/auth.lua"] = { "a😀b" } } })
    local snapshot = client(7, "utf16")
    local presentation, unique, failures = normalizer:locations({
      {
        client = snapshot,
        result = link(protocol_range(1, 3)),
      },
    })

    assert.same({ start = { line = 0, character = 1 }, ["end"] = { line = 0, character = 5 } }, unique[1].range)
    assert.equals(unique[1].identity, presentation[1].identity)
    assert.equals(7, presentation[1].client_id)
    assert.same({}, failures)
  end)

  it("sorts client responses, preserves multiplicity, and deduplicates flow input", function()
    local env, _, normalizer = setup({ files = { ["/project/lua/auth.lua"] = { "a😀b" } } })
    local raw = link(protocol_range(1, 3))
    local responses = {
      { client = client(9, "zeta"), result = raw },
      { client = client(8, "alpha"), result = raw },
      { client = client(2, "alpha"), result = raw },
    }

    local presentation, unique, failures, summary = normalizer:locations(responses)
    assert.same(
      { 2, 8, 9 },
      vim.tbl_map(function(item)
        return item.client_id
      end, presentation)
    )
    assert.same(
      { 1, 1, 1 },
      vim.tbl_map(function(item)
        return item.response_index
      end, presentation)
    )
    assert.equals(3, #presentation)
    assert.equals(1, #unique)
    assert.equals("auth.lua:1", unique[1].symbol)
    assert.equals("a😀b", unique[1].context)
    assert.same({ filename = "/project/lua/auth.lua", lnum = 1, col = 2, end_lnum = 1, end_col = 6 }, {
      filename = presentation[1].list_item.filename,
      lnum = presentation[1].list_item.lnum,
      col = presentation[1].list_item.col,
      end_lnum = presentation[1].list_item.end_lnum,
      end_col = presentation[1].list_item.end_col,
    })
    assert.same({}, failures)
    assert.same({ usable_response_count = 3, empty_response_count = 0, invalid_response_count = 0 }, summary)
    assert.same({}, env.buffers)
  end)

  it("prefers modified loaded source and returns its buffer as the list target", function()
    local env, _, normalizer = setup({
      files = { ["/project/lua/auth.lua"] = { "disk text" } },
      buffers = {
        { id = 17, name = "/project/lua/auth.lua", loaded = true, lines = { "local unsaved = true" } },
      },
    })
    local presentation, unique = normalizer:locations({
      { client = client(7, "loaded", "utf-8"), result = location(protocol_range(6, 13)) },
    })

    assert.equals("unsaved", unique[1].symbol)
    assert.equals("local unsaved = true", unique[1].context)
    assert.equals(17, presentation[1].list_item.bufnr)
    assert.is_nil(presentation[1].list_item.filename)
    assert.is_false(vim.tbl_contains(env.runtime.calls, "read_file:/project/lua/auth.lua"))
  end)

  it("falls back from a LocationLink selection range to its target range", function()
    local _, _, normalizer = setup({ files = { ["/project/lua/auth.lua"] = { "auth" } } })
    local raw = link(nil)
    raw.targetRange = protocol_range(0, 4)
    local presentation, unique = normalizer:locations({
      { client = client(7, "fallback", "utf-8"), result = raw },
    })

    assert.same({ start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 4 } }, unique[1].range)
    assert.equals(raw, presentation[1].raw)
  end)

  it("summarizes each invalid protocol-range shape without throwing", function()
    local _, _, normalizer = setup({ files = { ["/project/lua/auth.lua"] = { "a😀b", "tail" } } })
    local snapshot = client(7, "invalid")
    local invalid_ranges = {
      protocol_range(-1, 0),
      protocol_range(10, 10),
      protocol_range(2, 3),
      protocol_range(0, 0, 1, 0),
    }

    for _, range in ipairs(invalid_ranges) do
      local presentation, unique, failures, summary = normalizer:locations({
        { client = snapshot, result = location(range) },
      })
      assert.same({}, presentation)
      assert.same({}, unique)
      assert.same({ expected_failure(snapshot, 1, 1) }, failures)
      assert.same({ usable_response_count = 0, empty_response_count = 0, invalid_response_count = 1 }, summary)
    end
  end)

  it("omits an unresolved non-file URI with one exact failure", function()
    local _, _, normalizer = setup({})
    local snapshot = client(4, "jdt", "utf-8")
    local presentation, unique, failures = normalizer:locations({
      {
        client = snapshot,
        result = location(protocol_range(0, 1), "jdt://contents/Auth.class"),
      },
    })

    assert.same({}, presentation)
    assert.same({}, unique)
    assert.same({ expected_failure(snapshot, 1, 1) }, failures)
  end)

  it("retains valid items while reporting invalid items once per response", function()
    local _, _, normalizer = setup({ files = { ["/project/lua/auth.lua"] = { "auth" } } })
    local snapshot = client(3, "mixed", "utf-8")
    local presentation, unique, failures, summary = normalizer:locations({
      {
        client = snapshot,
        result = {
          location(protocol_range(0, 4)),
          location(protocol_range(9, 10)),
        },
      },
    })

    assert.equals(1, #presentation)
    assert.equals(1, #unique)
    assert.same({ expected_failure(snapshot, 1, 1) }, failures)
    assert.same({ usable_response_count = 1, empty_response_count = 0, invalid_response_count = 0 }, summary)
  end)

  it("counts nil and empty successful results as usable empty responses", function()
    local _, _, normalizer = setup({ files = { ["/project/lua/auth.lua"] = { "auth" } } })
    for _, kind in ipairs({ "nil", "empty_list" }) do
      local protocol_result = kind == "empty_list" and {} or nil
      local presentation, unique, failures, summary = normalizer:locations({
        { client = client(3, "empty", "utf-8"), result = protocol_result },
      })
      assert.same({}, presentation)
      assert.same({}, unique)
      assert.same({}, failures)
      assert.same({ usable_response_count = 1, empty_response_count = 1, invalid_response_count = 0 }, summary)
    end
  end)

  it("normalizes incoming and outgoing call sites with direction-specific locations", function()
    local _, locator, normalizer = setup({
      files = {
        ["/project/lua/caller.lua"] = { "caller target" },
        ["/project/lua/origin.lua"] = { "origin target" },
        ["/project/lua/callee.lua"] = { "callee body" },
      },
    })
    local snapshot = client(5, "calls", "utf-8")
    local caller = {
      name = "caller",
      kind = 12,
      uri = "file:///project/lua/caller.lua",
      selectionRange = protocol_range(0, 6),
      range = protocol_range(0, 13),
    }
    local prepared = {
      item = {
        name = "origin",
        uri = "file:///project/lua/origin.lua",
        selectionRange = protocol_range(0, 6),
        range = protocol_range(0, 8),
      },
    }

    local incoming = normalizer:call_sites("incoming", snapshot, prepared, {
      { from = caller, fromRanges = { protocol_range(7, 13), caller.range } },
    })
    assert.same(locator:from_uri(caller.uri), incoming[1].location.locator)
    assert.same(protocol_range(7, 13), incoming[1].location.range)
    assert.equals(caller.name, incoming[1].location.symbol)
    assert.equals("function", incoming[1].location.symbol_kind)
    assert.same({
      locator = locator:from_uri(caller.uri),
      range = protocol_range(0, 6),
      line_text = "caller target",
    }, incoming[1].location.query_anchor)
    assert.same({ 1, 2 }, { incoming[1].range_index, incoming[2].range_index })

    local callee = {
      name = "callee",
      kind = 6,
      uri = "file:///project/lua/callee.lua",
      selectionRange = protocol_range(0, 6),
      range = protocol_range(0, 11),
    }
    local outgoing = normalizer:call_sites("outgoing", snapshot, prepared, {
      { to = callee, fromRanges = { protocol_range(7, 13) } },
    })
    assert.same(locator:from_uri(prepared.item.uri), outgoing[1].location.locator)
    assert.same(protocol_range(7, 13), outgoing[1].location.range)
    assert.equals(callee.name, outgoing[1].location.symbol)
    assert.equals("method", outgoing[1].location.symbol_kind)
    assert.same({
      locator = locator:from_uri(callee.uri),
      range = protocol_range(0, 6),
      line_text = "callee body",
    }, outgoing[1].location.query_anchor)
  end)

  it("summarizes one call-hierarchy result as one usable response", function()
    local _, _, normalizer = setup({
      files = { ["/project/lua/caller.lua"] = { "caller()" } },
    })
    local snapshot = client(5, "calls", "utf-8")
    local caller = {
      name = "caller",
      uri = "file:///project/lua/caller.lua",
      selectionRange = protocol_range(0, 6),
    }
    local presentation, unique, failures, summary = normalizer:call_sites("incoming", snapshot, {}, {
      { from = caller, fromRanges = { protocol_range(0, 6) } },
      { from = caller, fromRanges = { protocol_range(20, 21) } },
    })

    assert.equals(1, #presentation)
    assert.equals(1, #unique)
    assert.same({ expected_failure(snapshot, 1, 1) }, failures)
    assert.same({ usable_response_count = 1, empty_response_count = 0, invalid_response_count = 0 }, summary)
  end)
end)
