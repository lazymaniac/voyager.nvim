local Config = require("voyager.config")

local command_names = {
  "VoyagerOpen",
  "VoyagerFocus",
  "VoyagerSave",
  "VoyagerLoad",
  "VoyagerClose",
  "VoyagerToggle",
  "VoyagerExport",
  "VoyagerBuild",
  "VoyagerBuildCancel",
}

local function delete_commands()
  for _, name in ipairs(command_names) do
    pcall(vim.api.nvim_del_user_command, name)
  end
end

describe("Voyager public interface", function()
  local original_runtime
  local original_session
  local original_voyager
  local original_notify
  local env

  before_each(function()
    delete_commands()
    original_runtime = package.loaded["voyager.runtime"]
    original_session = package.loaded["voyager.session"]
    original_voyager = package.loaded["voyager"]
    original_notify = vim.notify
    env = {
      calls = {},
      config_snapshots = {},
      native_calls = 0,
      notifications = {},
      runtime = {},
    }
    vim.notify = function(message, level)
      table.insert(env.notifications, { message = message, level = level })
    end

    package.loaded["voyager.runtime"] = {
      native = function()
        env.runtime_calls = (env.runtime_calls or 0) + 1
        return env.runtime
      end,
    }
    package.loaded["voyager.session"] = {
      native = function(config_provider, runtime)
        env.native_calls = env.native_calls + 1
        assert.equals(env.runtime, runtime)
        local controller = { active = false }
        local function call(name)
          table.insert(env.calls, { name = name, active = controller.active })
        end
        function controller:open()
          call("open")
          if self.active then
            return self:focus()
          end
          self.active = true
          table.insert(env.config_snapshots, config_provider())
          return true
        end
        function controller:focus()
          call("focus")
          return self.active or nil
        end
        function controller:save()
          call("save")
          return self.active or nil
        end
        function controller:load()
          call("load")
          if not self.active then
            table.insert(env.config_snapshots, config_provider())
          end
          return true
        end
        function controller:close(source)
          call("close")
          env.close_source = source
          local was_active = self.active
          self.active = false
          return was_active
        end
        function controller:shutdown()
          call("shutdown")
          self.active = false
        end
        function controller:is_active()
          return self.active
        end
        function controller:export()
          call("export")
          return self.active and 1 or nil
        end
        function controller:build(opts)
          call("build")
          env.build_opts = vim.deepcopy(opts)
          return self.active or nil
        end
        function controller:cancel_build()
          call("cancel_build")
          return self.active or nil
        end
        function controller:state()
          return {
            request_count = 2,
            flow = {
              name = "main",
              is_dirty = function()
                return true
              end,
              dfs = function()
                return {
                  { kind = "location" },
                  { kind = "action" },
                  { kind = "location" },
                }
              end,
            },
          }
        end
        env.controller = controller
        return controller
      end,
    }
    package.loaded["voyager"] = nil
  end)

  after_each(function()
    local voyager = package.loaded["voyager"]
    if voyager and voyager._reset_for_tests then
      voyager._reset_for_tests()
    end
    delete_commands()
    package.loaded["voyager"] = original_voyager
    package.loaded["voyager.runtime"] = original_runtime
    package.loaded["voyager.session"] = original_session
    vim.notify = original_notify
  end)

  it("registers commands without global mappings", function()
    local mappings_before = vim.api.nvim_get_keymap("n")
    vim.cmd("runtime plugin/voyager.lua")
    for _, command in ipairs(command_names) do
      assert.equals(2, vim.fn.exists(":" .. command))
    end
    assert.same(mappings_before, vim.api.nvim_get_keymap("n"))
    assert.same({ "callers", "callees" }, vim.fn.getcompletion("VoyagerBuild c", "cmdline"))
    assert.same({}, vim.fn.getcompletion("VoyagerBuild callers ", "cmdline"))

    vim.cmd("VoyagerOpen")
    vim.cmd("VoyagerFocus")
    vim.cmd("VoyagerSave")
    vim.cmd("VoyagerLoad")
    vim.cmd("VoyagerClose")
    vim.cmd("VoyagerToggle")
    vim.cmd("VoyagerExport")
    vim.cmd("VoyagerBuild callers 4")
    vim.cmd("VoyagerBuildCancel")
    assert.same(
      { "open", "focus", "save", "load", "close", "open", "export", "build", "cancel_build" },
      vim.tbl_map(function(call)
        return call.name
      end, env.calls)
    )
    assert.equals("command", env.close_source)
    assert.same({ direction = "callers", depth = 4 }, env.build_opts)
    assert.equals(1, env.native_calls)
    assert.equals(1, env.runtime_calls)
  end)

  it("rejects malformed recursive commands before creating a session", function()
    vim.cmd("runtime plugin/voyager.lua")
    for _, command in ipairs({
      "VoyagerBuild sideways",
      "VoyagerBuild callers 0",
      "VoyagerBuild callees 11",
      "VoyagerBuild callers nope",
      "VoyagerBuild callers 2 extra",
    }) do
      vim.cmd(command)
    end

    assert.equals(0, env.native_calls)
    assert.same({}, env.calls)
    assert.equals(5, #env.notifications)
    assert.matches("direction must be 'callers' or 'callees'", env.notifications[1].message, nil, true)
    assert.matches("depth must be an integer from 1 through 10", env.notifications[2].message, nil, true)
    assert.matches("depth must be an integer from 1 through 10", env.notifications[3].message, nil, true)
    assert.matches("usage: VoyagerBuild", env.notifications[4].message, nil, true)
    assert.matches("usage: VoyagerBuild", env.notifications[5].message, nil, true)
  end)

  it("rejects invalid Lua build options before opening or delegating", function()
    local Voyager = require("voyager")
    local invalid = {
      { direction = "sideways" },
      { depth = 0 },
      { depth = 11 },
      { depth = 1.5 },
      { max_subjects = 0 },
      { max_subjects = 1001 },
      { concurrency = 0 },
      { concurrency = 17 },
      { concurrency = "4" },
      { breadth = 4 },
      { origin_id = "" },
      { origin_id = 7 },
      "callees",
    }
    for _, opts in ipairs(invalid) do
      assert.is_nil(Voyager.build(opts))
    end

    assert.equals(0, env.native_calls)
    assert.same({}, env.calls)
    assert.equals(#invalid, #env.notifications)
    assert.matches("breadth is not a supported option", env.notifications[10].message, nil, true)
    assert.matches("origin_id must be a non-empty string", env.notifications[11].message, nil, true)
    assert.matches("origin_id must be a non-empty string", env.notifications[12].message, nil, true)

    assert.is_true(Voyager.open())
    assert.is_nil(Voyager.build({ max_subjects = 1001 }))
    assert.same(
      { "open" },
      vim.tbl_map(function(call)
        return call.name
      end, env.calls)
    )
  end)

  it("accepts every supported Lua build option at its upper boundary", function()
    local Voyager = require("voyager")
    local opts = {
      direction = "callers",
      depth = 10,
      max_subjects = 1000,
      concurrency = 16,
      origin_id = "location-1",
    }

    assert.is_true(Voyager.build(opts))
    assert.same(opts, env.build_opts)
    assert.same(
      { "open", "build" },
      vim.tbl_map(function(call)
        return call.name
      end, env.calls)
    )
  end)

  it("opens a session before starting a build and ignores cancellation while inactive", function()
    local Voyager = require("voyager")

    assert.is_nil(Voyager.cancel_build())
    assert.is_true(Voyager.build())

    assert.same(
      { "open", "build" },
      vim.tbl_map(function(call)
        return call.name
      end, env.calls)
    )
    assert.is_nil(env.build_opts)
  end)

  it("reports statusline data only while a session is active", function()
    local Voyager = require("voyager")
    assert.is_nil(Voyager.status())
    Voyager.open()
    assert.same({ name = "main", dirty = true, locations = 2, requests = 2 }, Voyager.status())
    Voyager.close()
    assert.is_nil(Voyager.status())
  end)

  it("validates setup immediately and snapshots configuration only for future sessions", function()
    local Voyager = require("voyager")
    assert.has_error(function()
      Voyager.setup({ sidebar = { width = 10 } })
    end, "voyager.setup: sidebar.width must be an integer of at least 20")
    assert.equals(0, env.native_calls)

    local opts = { sidebar = { width = 50 } }
    Voyager.setup(opts)
    opts.sidebar.width = 70
    Voyager.open()
    assert.equals(50, env.config_snapshots[1].sidebar.width)

    Voyager.setup({ sidebar = { width = 60 } })
    Voyager.open()
    assert.equals(1, #env.config_snapshots)
    assert.equals("focus", env.calls[#env.calls].name)

    Voyager.close()
    Voyager.open()
    assert.equals(60, env.config_snapshots[2].sidebar.width)
    assert.same(Config.resolve({ sidebar = { width = 60 } }), env.config_snapshots[2])
  end)

  it("delegates inactive operations and resets the controller and configuration", function()
    local Voyager = require("voyager")
    Voyager.focus()
    Voyager.save()
    Voyager.load()
    Voyager.close()
    assert.same(
      { "focus", "save", "load", "close" },
      vim.tbl_map(function(call)
        return call.name
      end, env.calls)
    )

    Voyager.setup({ sidebar = { width = 55 } })
    Voyager._reset_for_tests()
    assert.equals("shutdown", env.calls[#env.calls].name)
    Voyager.open()
    assert.equals(2, env.native_calls)
    assert.equals(42, env.config_snapshots[#env.config_snapshots].sidebar.width)
  end)
end)
