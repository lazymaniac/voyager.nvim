local Symbols = require("voyager.symbols")

local function range(start_line, start_character, end_line, end_character)
  return {
    start = { line = start_line, character = start_character },
    ["end"] = { line = end_line, character = end_character },
  }
end

local function location(path, line, character)
  return {
    locator = { kind = "project", path = path },
    range = range(line, character, line, character + 4),
  }
end

describe("Voyager symbol resolution", function()
  it("follows the deepest containing document symbol and qualifies the last two names", function()
    local symbols = {
      {
        name = "com.jane.platform",
        kind = 4,
        range = range(0, 0, 100, 0),
        children = {
          {
            name = "DurableObservationIngressService",
            kind = 5,
            range = range(4, 0, 60, 1),
            selectionRange = range(4, 6, 4, 38),
            children = {
              {
                name = "accept",
                kind = 6,
                range = range(10, 2, 20, 3),
                selectionRange = range(10, 4, 10, 10),
                children = {},
              },
              {
                name = "reject",
                kind = 6,
                range = range(22, 2, 30, 3),
                selectionRange = range(22, 4, 22, 10),
                children = {},
              },
            },
          },
        },
      },
    }

    local symbol, kind, anchor_range = Symbols.from_document_symbols(symbols, { line = 12, character = 8 })
    assert.equals("DurableObservationIngressService.accept", symbol)
    assert.equals("method", kind)
    assert.same(range(10, 4, 10, 10), anchor_range)

    local class_only, class_kind = Symbols.from_document_symbols(symbols, { line = 5, character = 0 })
    assert.equals("com.jane.platform.DurableObservationIngressService", class_only)
    assert.equals("class", class_kind)

    assert.is_nil(Symbols.from_document_symbols(symbols, { line = 200, character = 0 }))
  end)

  it("picks the smallest containing flat symbol and qualifies with its container", function()
    local symbols = {
      {
        name = "DurableObservationIngressService",
        kind = 5,
        location = { uri = "file:///x", range = range(4, 0, 60, 1) },
      },
      {
        name = "accept",
        kind = 6,
        containerName = "DurableObservationIngressService",
        location = { uri = "file:///x", range = range(10, 2, 20, 3) },
      },
    }

    local symbol, kind, anchor_range = Symbols.from_symbol_information(symbols, { line = 12, character = 8 })
    assert.equals("DurableObservationIngressService.accept", symbol)
    assert.equals("method", kind)
    assert.same(range(10, 2, 20, 3), anchor_range)

    local outer = Symbols.from_symbol_information(symbols, { line = 40, character = 0 })
    assert.equals("DurableObservationIngressService", outer)
  end)

  it("detects response shapes and rejects unknown ones", function()
    local hierarchical = { { name = "a", kind = 12, range = range(0, 0, 2, 0), children = {} } }
    local flat = { { name = "a", kind = 12, location = { uri = "u", range = range(0, 0, 2, 0) } } }
    assert.equals("a", (Symbols.from_response(hierarchical, { line = 1, character = 0 })))
    assert.equals("a", (Symbols.from_response(flat, { line = 1, character = 0 })))
    assert.is_nil((Symbols.from_response({ "garbage" }, { line = 1, character = 0 })))
    assert.is_nil((Symbols.from_response(nil, { line = 1, character = 0 })))
  end)

  it("resolves through a documentSymbol client for open buffers", function()
    local captured
    local lines = {}
    for index = 1, 31 do
      lines[index] = string.rep("x", 16)
    end
    lines[11] = "😀accept"
    lines[25] = "  reject"
    local service = Symbols.new({
      locator = {
        list_target = function()
          return { bufnr = 7 }
        end,
        source = function()
          return lines
        end,
      },
      get_clients = function(opts)
        assert.equals(7, opts.bufnr)
        assert.equals("textDocument/documentSymbol", opts.method)
        return { { id = 1, name = "server", offset_encoding = "utf-16" } }
      end,
      request_group = {
        start = function(opts)
          captured = opts
          return {}
        end,
      },
      timer = function() end,
      filetype_match = function()
        return nil
      end,
    })

    local results
    service:resolve({
      { node_id = "loc-a", uri = "file:///s.java", location = location("s.java", 12, 8) },
      { node_id = "loc-b", uri = "file:///s.java", location = location("s.java", 25, 4) },
    }, { timeout_ms = 500 }, function(value)
      results = value
    end)

    assert.is_nil(results)
    assert.equals("textDocument/documentSymbol", captured.method)
    assert.same({ textDocument = { uri = "file:///s.java" } }, captured.make_params())
    captured.on_complete({
      status = "success",
      responses = {
        {
          client = { id = 1, name = "server", offset_encoding = "utf-16" },
          result = {
            {
              name = "Service",
              kind = 5,
              range = range(0, 0, 60, 1),
              selectionRange = range(0, 0, 0, 7),
              children = {
                {
                  name = "accept",
                  kind = 6,
                  range = range(10, 0, 20, 1),
                  selectionRange = range(10, 2, 10, 8),
                  children = {},
                },
                {
                  name = "reject",
                  kind = 6,
                  range = range(24, 0, 30, 1),
                  selectionRange = range(24, 2, 24, 8),
                  children = {},
                },
              },
            },
          },
        },
      },
      failures = {},
    })

    assert.same({
      ["loc-a"] = {
        symbol = "Service.accept",
        kind = "method",
        query_anchor = {
          locator = { kind = "project", path = "s.java" },
          range = range(10, 4, 10, 10),
          line_text = "😀accept",
        },
      },
      ["loc-b"] = {
        symbol = "Service.reject",
        kind = "method",
        query_anchor = {
          locator = { kind = "project", path = "s.java" },
          range = range(24, 2, 24, 8),
          line_text = "  reject",
        },
      },
    }, results)
  end)

  it("falls back to treesitter when no client can serve the file", function()
    local lines = {
      "local M = {}",
      "function M.save(value)",
      "  return value",
      "end",
      "return M",
    }
    local service = Symbols.new({
      locator = {
        list_target = function()
          return { filename = "/repo/lua/store.lua" }
        end,
        source = function()
          return lines
        end,
      },
      get_clients = function()
        return {}
      end,
      request_group = {
        start = function()
          error("unexpected LSP dispatch")
        end,
      },
      timer = function() end,
      filetype_match = function()
        return "lua"
      end,
      get_string_parser = vim.treesitter.get_string_parser,
      get_node_text = vim.treesitter.get_node_text,
    })

    local results
    service:resolve({
      { node_id = "loc-save", uri = "file:///repo/lua/store.lua", location = location("lua/store.lua", 2, 4) },
    }, { timeout_ms = 500 }, function(value)
      results = value
    end)

    assert.is_table(results)
    assert.equals("M.save", results["loc-save"].symbol)
    assert.equals("function", results["loc-save"].kind)
    assert.same({
      locator = { kind = "project", path = "lua/store.lua" },
      range = range(1, 9, 1, 15),
      line_text = "function M.save(value)",
    }, results["loc-save"].query_anchor)
  end)

  it("reports an empty result set when nothing resolves", function()
    local service = Symbols.new({
      locator = {
        list_target = function()
          return nil
        end,
        source = function()
          return nil
        end,
      },
      get_clients = function()
        return {}
      end,
      request_group = { start = function() end },
      timer = function() end,
      filetype_match = function()
        return nil
      end,
    })
    local results
    service:resolve({
      { node_id = "loc-x", uri = "file:///gone.lua", location = location("gone.lua", 0, 0) },
    }, { timeout_ms = 500 }, function(value)
      results = value
    end)
    assert.same({}, results)
  end)
end)
