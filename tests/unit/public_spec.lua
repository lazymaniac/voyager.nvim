local Config = require("voyager.config")

local command_names = {
  "VoyagerOpen",
  "VoyagerFocus",
  "VoyagerSave",
  "VoyagerLoad",
  "VoyagerClose",
  "VoyagerToggle",
  "VoyagerExport",
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
    assert.equals(0, vim.fn.exists(":VoyagerBuild"))
    assert.equals(0, vim.fn.exists(":VoyagerBuildCancel"))
    assert.same(mappings_before, vim.api.nvim_get_keymap("n"))

    vim.cmd("VoyagerOpen")
    vim.cmd("VoyagerFocus")
    vim.cmd("VoyagerSave")
    vim.cmd("VoyagerLoad")
    vim.cmd("VoyagerClose")
    vim.cmd("VoyagerToggle")
    vim.cmd("VoyagerExport")
    assert.same(
      { "open", "focus", "save", "load", "close", "open", "export" },
      vim.tbl_map(function(call)
        return call.name
      end, env.calls)
    )
    assert.equals("command", env.close_source)
    assert.equals(1, env.native_calls)
    assert.equals(1, env.runtime_calls)
  end)

  it("does not expose manual build functions", function()
    local Voyager = require("voyager")
    assert.is_nil(Voyager.build)
    assert.is_nil(Voyager.cancel_build)
    assert.equals(0, env.native_calls)
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
