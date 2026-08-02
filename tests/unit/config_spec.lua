local Config = require("voyager.config")

describe("Voyager configuration", function()
  it("returns an isolated complete snapshot", function()
    local first = Config.resolve({ sidebar = { width = 50 } })
    local second = Config.resolve({})
    assert.same(50, first.sidebar.width)
    assert.same(42, second.sidebar.width)
    assert.same("grr", second.lsp_keymaps.references)
    assert.same({ "q", "<Esc>" }, second.sidebar_keymaps.close)
  end)

  it("accepts disabled mappings and a URI resolver", function()
    local resolver = function()
      return 7
    end
    local config = Config.resolve({
      lsp_keymaps = { declaration = false },
      sidebar_keymaps = { close = false },
      storage = { resolve_uri = resolver },
    })
    assert.is_false(config.lsp_keymaps.declaration)
    assert.is_false(config.sidebar_keymaps.close)
    assert.equals(resolver, config.storage.resolve_uri)
  end)

  it("rejects invalid values with their full path", function()
    assert.has_error(function()
      Config.resolve({ sidebar = { side = "top" } })
    end, "voyager.setup: sidebar.side must be 'left' or 'right'")
    assert.has_error(function()
      Config.resolve({ lsp_keymaps = { definition = "" } })
    end, "voyager.setup: lsp_keymaps.definition must be false or a non-empty normal-mode LHS")
    assert.has_error(function()
      Config.resolve({ sidebar_keymaps = { close = {} } })
    end, "voyager.setup: sidebar_keymaps.close must not be an empty list")
    assert.has_error(function()
      Config.resolve({ lsp_keymaps = { definition = "gd", declaration = "gd" } })
    end, "voyager.setup: lsp_keymaps contains duplicate normalized LHS 'gd'")
  end)
end)
