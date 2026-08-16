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

  it("resolves the new sidebar, storage, and keymap defaults", function()
    local config = Config.resolve()
    assert.equals("relative", config.sidebar.path)
    assert.is_false(config.storage.autosave)
    assert.equals("▲", config.sidebar.icons.caller)
    assert.equals("▼", config.sidebar.icons.callee)
    assert.equals("o", config.sidebar_keymaps.jump_stay)
    assert.equals("a", config.sidebar_keymaps.run_action)
    assert.equals("u", config.sidebar_keymaps.show_callers)
    assert.equals("d", config.sidebar_keymaps.show_callees)
    assert.equals("U", config.sidebar_keymaps.refresh_callers)
    assert.equals("D", config.sidebar_keymaps.refresh_callees)
    assert.equals("ru", config.sidebar_keymaps.build_callers)
    assert.equals("rd", config.sidebar_keymaps.build_callees)
    assert.equals("rc", config.sidebar_keymaps.cancel_build)
    assert.equals("x", config.sidebar_keymaps.delete)
    assert.equals("p", config.sidebar_keymaps.preview)
    assert.equals("zM", config.sidebar_keymaps.collapse_all)
    assert.equals("zR", config.sidebar_keymaps.expand_all)
    assert.equals("?", config.sidebar_keymaps.help)
    assert.same({
      direction = "callees",
      depth = 3,
      max_subjects = 32,
      concurrency = 4,
    }, config.navigation.recursive)

    assert.equals("filename", Config.resolve({ sidebar = { path = "filename" } }).sidebar.path)
    assert.is_true(Config.resolve({ storage = { autosave = true } }).storage.autosave)
    assert.has_error(function()
      Config.resolve({ sidebar = { path = "long" } })
    end, "voyager.setup: sidebar.path must be 'relative', 'filename', or 'shortened'")
    assert.has_error(function()
      Config.resolve({ storage = { autosave = "yes" } })
    end, "voyager.setup: storage.autosave must be a boolean")
  end)

  it("resolves and validates bounded recursive navigation", function()
    local config = Config.resolve({
      navigation = {
        recursive = {
          direction = "callers",
          depth = 5,
          max_subjects = 1000,
          concurrency = 16,
        },
      },
    })
    assert.same({
      direction = "callers",
      depth = 5,
      max_subjects = 1000,
      concurrency = 16,
    }, config.navigation.recursive)
    assert.equals("callees", Config.resolve().navigation.recursive.direction)
    assert.same({
      direction = "callers",
      depth = 3,
      max_subjects = 32,
      concurrency = 4,
    }, Config.resolve({ navigation = { recursive = { direction = "callers" } } }).navigation.recursive)

    local invalid = {
      { { direction = "both" }, "direction must be 'callers' or 'callees'" },
      { { depth = 0 }, "depth must be an integer from 1 through 10" },
      { { depth = 11 }, "depth must be an integer from 1 through 10" },
      { { depth = 10.5 }, "depth must be an integer from 1 through 10" },
      { { max_subjects = 0 }, "max_subjects must be an integer from 1 through 1000" },
      { { max_subjects = 1001 }, "max_subjects must be an integer from 1 through 1000" },
      { { concurrency = 0 }, "concurrency must be an integer from 1 through 16" },
      { { concurrency = 17 }, "concurrency must be an integer from 1 through 16" },
    }
    for _, case in ipairs(invalid) do
      assert.has_error(function()
        Config.resolve({ navigation = { recursive = case[1] } })
      end, "voyager.setup: navigation.recursive." .. case[2])
    end
    assert.has_error(function()
      Config.resolve({ navigation = { recursive = "callees" } })
    end, "voyager.setup: navigation.recursive must be a table")
    assert.has_error(function()
      Config.resolve({ navigation = { recursive = { breadth = 4 } } })
    end, "voyager.setup: navigation.recursive.breadth is not a supported option")
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

  it("resolves preview, test-path, and kind-icon defaults with overrides", function()
    local config = Config.resolve()
    assert.is_true(config.sidebar.preview)
    assert.is_table(config.sidebar.test_paths)
    assert.is_true(#config.sidebar.test_paths > 0)
    assert.is_table(config.sidebar.icons.kinds)
    assert.is_string(config.sidebar.icons.kinds.class)

    local plain = Config.resolve({ sidebar = { icons = false } }).sidebar.icons
    assert.equals("[C]", plain.kinds.class)
    assert.equals("[I]", plain.kinds.interface)
    assert.equals("[R]", plain.kinds.record)

    local merged = Config.resolve({ sidebar = { icons = { kinds = { class = "K" } } } }).sidebar.icons
    assert.equals("K", merged.kinds.class)
    assert.equals(Config.resolve().sidebar.icons.kinds.interface, merged.kinds.interface)

    local custom = Config.resolve({ sidebar = { preview = false, test_paths = { "/qa/" }, indent = 2 } })
    assert.is_false(custom.sidebar.preview)
    assert.same({ "/qa/" }, custom.sidebar.test_paths)
    assert.equals(2, custom.sidebar.indent)
    assert.equals(1, Config.resolve().sidebar.indent)

    assert.has_error(function()
      Config.resolve({ sidebar = { indent = 9 } })
    end, "voyager.setup: sidebar.indent must be an integer from 0 through 8")
    assert.has_error(function()
      Config.resolve({ sidebar = { indent = 1.5 } })
    end, "voyager.setup: sidebar.indent must be an integer from 0 through 8")

    assert.has_error(function()
      Config.resolve({ sidebar = { preview = "on" } })
    end, "voyager.setup: sidebar.preview must be a boolean")
    assert.has_error(function()
      Config.resolve({ sidebar = { test_paths = "/qa/" } })
    end, "voyager.setup: sidebar.test_paths must be a list of Lua patterns")
    assert.has_error(function()
      Config.resolve({ sidebar = { test_paths = { "" } } })
    end, "voyager.setup: sidebar.test_paths[1] must be a non-empty Lua pattern")
    assert.has_error(function()
      Config.resolve({ sidebar = { icons = { kinds = { classy = "K" } } } })
    end, "voyager.setup: sidebar.icons.kinds.classy is not a supported option")
    assert.has_error(function()
      Config.resolve({ sidebar = { icons = { kinds = { class = 7 } } } })
    end, "voyager.setup: sidebar.icons.kinds.class must be a string")
    assert.has_error(function()
      Config.resolve({ sidebar = { icons = { kinds = "big" } } })
    end, "voyager.setup: sidebar.icons.kinds must be a table of kind icon overrides")
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
      Config.resolve({ sidebar_keymaps = { show_callers = "d" } })
    end, "voyager.setup: sidebar_keymaps contains duplicate normalized LHS 'd'")
    assert.has_error(function()
      Config.resolve({ sidebar_keymaps = { build_callers = "rd" } })
    end, "voyager.setup: sidebar_keymaps contains duplicate normalized LHS 'rd'")
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
