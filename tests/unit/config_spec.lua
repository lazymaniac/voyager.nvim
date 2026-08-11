local Config = require("voyager.config")

describe("Voyager configuration", function()
  it("returns an isolated complete snapshot", function()
    local first = Config.resolve({ sidebar = { width = 50 } })
    local second = Config.resolve({})
    assert.same(50, first.sidebar.width)
    assert.same(42, second.sidebar.width)
    assert.same({ "q", "<Esc>" }, second.sidebar_keymaps.close)
    assert.is_table(second.sidebar.icons)
    assert.equals("●", second.sidebar.icons.current)
    assert.is_string(second.sidebar.icons.references)
  end)

  it("accepts disabled mappings and a URI resolver", function()
    local resolver = function()
      return 7
    end
    local config = Config.resolve({
      sidebar_keymaps = { close = false },
      storage = { resolve_uri = resolver },
    })
    assert.is_false(config.sidebar_keymaps.close)
    assert.equals(resolver, config.storage.resolve_uri)
  end)

  it("resolves icon presets and merges overrides", function()
    local plain = Config.resolve({ sidebar = { icons = false } }).sidebar.icons
    assert.equals("!", plain.stale)
    assert.equals("✎", plain.note)
    assert.equals("", plain.references)

    local nerd = Config.resolve({ sidebar = { icons = true } }).sidebar.icons
    assert.equals(nerd.references, Config.resolve().sidebar.icons.references)
    assert.is_true(nerd.references ~= "")

    local merged = Config.resolve({ sidebar = { icons = { references = "R", collapsed = "+" } } }).sidebar.icons
    assert.equals("R", merged.references)
    assert.equals("+", merged.collapsed)
    assert.equals(nerd.definition, merged.definition)
  end)

  it("rejects invalid values with their full path", function()
    assert.has_error(function()
      Config.resolve({ sidebar = { side = "top" } })
    end, "voyager.setup: sidebar.side must be 'left' or 'right'")
    assert.has_error(function()
      Config.resolve({ navigation = { on_list = function() end } })
    end, "voyager.setup: navigation.on_list is not a supported option")
    assert.has_error(function()
      Config.resolve({ lsp_keymaps = { definition = "gd" } })
    end, "voyager.setup: opts.lsp_keymaps is not a supported option")
    assert.has_error(function()
      Config.resolve({ sidebar_keymaps = { close = {} } })
    end, "voyager.setup: sidebar_keymaps.close must not be an empty list")
    assert.has_error(function()
      Config.resolve({ sidebar_keymaps = { note = "s", save = "s" } })
    end, "voyager.setup: sidebar_keymaps contains duplicate normalized LHS 's'")
    assert.has_error(function()
      Config.resolve({ sidebar = { icons = "fancy" } })
    end, "voyager.setup: sidebar.icons must be true, false, or a table of icon overrides")
    assert.has_error(function()
      Config.resolve({ sidebar = { icons = { reference = "R" } } })
    end, "voyager.setup: sidebar.icons.reference is not a supported option")
    assert.has_error(function()
      Config.resolve({ sidebar = { icons = { references = 7 } } })
    end, "voyager.setup: sidebar.icons.references must be a string")
  end)
end)
