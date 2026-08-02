local FakeSessionDeps = require("tests.helpers.fake_session_deps")
local Session = require("voyager.session")

local function new_session(overrides)
  local deps = FakeSessionDeps.new(overrides)
  return Session.new(deps:session_options()), deps
end

describe("Voyager session lifecycle", function()
  it("rejects unnamed and special origin buffers without side effects", function()
    for _, overrides in ipairs({
      { buffer_name = "" },
      { buffer_name = "/project/term", buftype = "terminal" },
    }) do
      local session, deps = new_session(overrides)
      assert.is_nil(session:open())
      assert.is_false(session:is_active())
      assert.equals(0, #deps.sidebar.mount_calls)
      assert.same({}, deps.keymaps.applied_buffers)
      assert.same({}, deps.autocmd_calls)
    end
  end)

  it("atomically opens a clean flow from a normal named buffer", function()
    local session, deps = new_session()
    assert.is_true(session:open())
    assert.is_true(session:is_active())
    assert.equals("active", session:state().phase)
    assert.equals(deps.origin_win, session:state().source_windows[1])
    assert.equals(deps.root_id, session:state().flow.current_node_id)
    assert.is_false(session:state().flow:is_dirty())
    assert.same({ deps.origin_buf }, deps.keymaps.applied_buffers)
    assert.is_false(deps.sidebar.mount_calls[1].focus)
    assert.equals(1, deps.sidebar.render_count)
    assert.equals(8, #deps.autocmd_calls)
  end)

  it("does not publish a session when the initial sidebar cannot mount", function()
    local session, deps = new_session()
    deps.sidebar.mount_result = false
    deps.sidebar.mount_error = "editor must be at least 24 columns wide"
    assert.is_nil(session:open())
    assert.is_false(session:is_active())
    assert.same({}, deps.keymaps.applied_buffers)
    assert.same({}, deps.autocmd_calls)
    assert.same({ { owned = true } }, deps.sidebar.unmount_calls)
    assert.matches("24 columns", deps.notifications[#deps.notifications].message)
  end)

  it("accepts a named unsaved buffer and rejects entropy failure before mounting", function()
    local session, deps = new_session({ buffer_name = "/project/lua/new.lua" })
    assert.is_true(session:open())
    assert.equals("new.lua", session:state().flow.root.location.locator.path:match("([^/]+)$"))

    session, deps = new_session()
    deps.random_error = "entropy unavailable"
    assert.is_nil(session:open())
    assert.is_false(session:is_active())
    assert.equals(0, #deps.sidebar.mount_calls)
    assert.same({}, deps.keymaps.applied_buffers)
    assert.same({}, deps.autocmd_calls)
    assert.matches("entropy unavailable", deps.notifications[1].message, nil, true)
  end)

  it("keeps an existing session and focuses or remounts its popup", function()
    local session, deps = new_session()
    assert.is_true(session:open())
    local flow = session:state().flow
    assert.is_true(session:open())
    assert.equals(flow, session:state().flow)
    assert.equals(1, #deps.sidebar.mount_calls)
    assert.equals(1, deps.sidebar.focus_count)

    deps.sidebar.mounted = false
    assert.is_true(session:focus())
    assert.is_true(deps.sidebar.remount_calls[#deps.sidebar.remount_calls].focus)

    deps.sidebar.mounted = false
    deps.sidebar.remount_result = false
    deps.sidebar.remount_error = "editor must be at least 24 columns wide"
    assert.is_nil(session:focus())
    assert.is_true(session:is_active())
    assert.matches("24 columns", deps.notifications[#deps.notifications].message)
  end)

  it("remounts without focus across tabs and resize validity changes", function()
    local session, deps = new_session()
    assert.is_true(session:open())
    deps:trigger("TabEnter")
    assert.is_false(deps.sidebar.remount_calls[#deps.sidebar.remount_calls].focus)

    deps.sidebar.remount_result = false
    deps.sidebar.remount_error = "too small"
    deps:trigger("VimResized")
    assert.is_false(deps.sidebar:is_mounted())
    assert.is_true(session:is_active())

    deps.sidebar.remount_result = true
    deps:trigger("VimResized")
    assert.is_true(deps.sidebar:is_mounted())
    assert.is_false(deps.sidebar.remount_calls[#deps.sidebar.remount_calls].focus)
  end)

  it("tracks recent source windows, evicts closed candidates, and never creates a split", function()
    local session, deps = new_session()
    assert.is_true(session:open())
    deps:add_buffer(12, "/project/lua/other.lua")
    deps:add_window(22, 12)
    deps.current_win_id = 22
    deps:trigger("WinEnter", { buf = 12 })
    assert.equals(22, session:state().source_windows[1])
    assert.equals(22, session:choose_jump_window())
    deps:trigger("CursorMoved")
    assert.same({ 22 }, deps.presenter.cursor_calls)

    deps.windows[22].valid = false
    deps:trigger("WinClosed", { match = "22" })
    assert.same({ deps.origin_win }, session:state().source_windows)
    assert.equals(deps.origin_win, session:choose_jump_window())

    deps.windows[deps.origin_win].valid = false
    deps:add_buffer(13, "/project/lua/fallback.lua")
    deps:add_window(23, 13)
    assert.equals(23, session:choose_jump_window())
    deps.windows[23].valid = false
    local window_count = vim.tbl_count(deps.windows)
    assert.is_nil(session:choose_jump_window())
    assert.matches("no eligible source window", deps.notifications[#deps.notifications].message)
    assert.equals(window_count, vim.tbl_count(deps.windows))
  end)

  it("closes cleanly once and restores focus only from Voyager UI", function()
    local session, deps = new_session()
    assert.is_true(session:open())
    local generation = session:state().generation
    local request = { cancel_calls = {} }
    function request:cancel(reason) table.insert(self.cancel_calls, reason) end
    session:state().request_handles[1] = request

    session:close("command")
    assert.is_false(session:is_active())
    assert.equals("closed", session:state().phase)
    assert.equals(generation + 1, session:state().generation)
    assert.same({ "command" }, request.cancel_calls)
    assert.equals(1, deps.presenter.invalidate_calls)
    assert.same({ generation }, deps.keymaps.restored_generations)
    assert.same({ deps.created_augroup.id }, deps.deleted_augroups)
    assert.same({ { owned = true } }, deps.sidebar.unmount_calls)
    assert.equals(deps.origin_win, deps.current_win_id)

    session:close("again")
    assert.equals(1, #deps.sidebar.unmount_calls)
    assert.equals(1, #deps.keymaps.restored_generations)

    session, deps = new_session()
    assert.is_true(session:open())
    deps.sidebar:focus()
    assert.equals(deps.sidebar.winid, deps.current_win_id)
    session:close("sidebar")
    assert.equals(deps.origin_win, deps.current_win_id)
  end)

  it("shutdown never asks about a dirty flow", function()
    local session, deps = new_session()
    assert.is_true(session:open())
    assert.is_true(session:state().flow:set_note(deps.root_id, "dirty"))
    session:shutdown()
    assert.is_false(session:is_active())
    assert.is_nil(deps.select_callback)
  end)

  it("wires native sidebar and presenter callbacks back to one controller", function()
    local deps = FakeSessionDeps.new()
    local captured = {}
    local factories = {
      flow = deps.flow_module,
      locator = function(project_root, resolve_uri)
        captured.locator = { project_root = project_root, resolve_uri = resolve_uri }
        return deps.locator
      end,
      store = function(locator)
        assert.equals(deps.locator, locator)
        return deps.store
      end,
      keymaps = function() return deps.keymaps end,
      sidebar = function(opts)
        captured.sidebar = opts
        return deps.sidebar
      end,
      lsp = function(locator, config)
        captured.lsp = { locator = locator, config = config }
        return deps.lsp
      end,
      presenter = function(opts)
        captured.presenter = opts
        return deps.presenter
      end,
    }
    local session = Session.native(function() return vim.deepcopy(deps.config) end, deps.runtime, factories)
    assert.is_true(session:open())
    assert.same({
      project_root = deps.project_root,
      resolve_uri = deps.config.storage.resolve_uri,
    }, captured.locator)
    assert.equals(deps.locator, captured.lsp.locator)
    assert.same(deps.config, captured.lsp.config)
    assert.same(deps.config.navigation, captured.presenter.navigation)

    local row = { kind = "location", owner_id = deps.root_id }
    local calls = {}
    session.activate_row = function(_, value) calls.activate = value end
    session.edit_note = function(_, value) calls.note = value end
    session.toggle_row = function(_, value) calls.toggle = value end
    session.save = function() calls.save = true end
    session.load = function() calls.load = true end
    session.close = function(_, source) calls.close = source end
    session.set_current = function(_, node_id) calls.current = node_id end
    session.choose_jump_window = function() return deps.origin_win end

    captured.sidebar.handlers.activate(row)
    captured.sidebar.handlers.note(row)
    captured.sidebar.handlers.toggle(row)
    captured.sidebar.handlers.save()
    captured.sidebar.handlers.load()
    captured.sidebar.handlers.close()
    assert.equals(row, calls.activate)
    assert.equals(row, calls.note)
    assert.equals(row, calls.toggle)
    assert.is_true(calls.save)
    assert.is_true(calls.load)
    assert.equals("sidebar", calls.close)

    captured.sidebar.handlers.external_close()
    assert.equals("external_popup", calls.close)
    assert.equals(deps.origin_win, captured.presenter.choose_window())
    captured.presenter.set_current(deps.root_id)
    assert.equals(deps.root_id, calls.current)
    assert.equals(deps.flow:location(deps.root_id), captured.presenter.resolve_node(deps.root_id))
  end)
end)
