local FakeSessionDeps = require("tests.helpers.fake_session_deps")
local Fixtures = require("tests.helpers.flow")
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

  it("dispatches typed rows without confusing locations, actions, and notes", function()
    local session, deps = new_session()
    assert.is_true(session:open())
    local result = Fixtures.location("lua/result.lua", 3, "result")
    local commit = session:state().flow:commit_navigation({
      origin_node_id = deps.root_id,
      method = "textDocument/implementation",
      label = "implementations",
      locations = { result },
    })
    local result_id = commit.node_id_by_identity[result.identity]
    local action_id = commit.action_id
    deps:add_buffer(12, "/project/lua/result.lua", { lines = { "one", "two", "three", "result" } })
    deps.locator.open_target_result = { bufnr = 12, row = 4, col = 0 }

    assert.is_true(session:activate_row({ kind = "location", owner_id = result_id }))
    assert.equals(result_id, session:state().flow.current_node_id)
    assert.equals(12, deps.windows[deps.origin_win].bufnr)
    assert.same({ 4, 0 }, deps.windows[deps.origin_win].cursor)
    assert.same({ deps.origin_win }, deps.fold_open_calls)

    deps.windows[deps.origin_win].bufnr = deps.origin_buf
    assert.is_true(session:activate_row({ kind = "note", owner_id = deps.root_id }))
    assert.equals(deps.root_id, session:state().flow.current_node_id)

    local collapsed = session:state().flow:find(action_id).collapsed
    assert.is_true(session:activate_row({ kind = "action", owner_id = action_id }))
    assert.equals(not collapsed, session:state().flow:find(action_id).collapsed)
    assert.is_true(session:toggle_row({ kind = "action", owner_id = action_id }))
    assert.equals(collapsed, session:state().flow:find(action_id).collapsed)

    local renders = deps.sidebar.render_count
    assert.is_false(session:toggle_row({ kind = "location", owner_id = deps.root_id }))
    assert.is_nil(session:edit_note({ kind = "action", owner_id = action_id }))
    assert.equals(renders, deps.sidebar.render_count)
    assert.matches("action row", deps.notifications[#deps.notifications].message, nil, true)
  end)

  it("warns and preserves logical current when a sidebar target cannot open", function()
    local session, deps = new_session()
    assert.is_true(session:open())
    local result = Fixtures.location("lua/stale.lua", 0)
    local commit = session:state().flow:commit_navigation({
      origin_node_id = deps.root_id,
      method = "textDocument/definition",
      label = "definition",
      locations = { result },
    })
    local result_id = commit.node_id_by_identity[result.identity]

    deps.locator.stale = true
    deps.locator.stale_reason = "file changed"
    assert.is_false(session:activate_row({ kind = "location", owner_id = result_id }))
    assert.equals(deps.root_id, session:state().flow.current_node_id)
    assert.is_true(session:state().flow:location(result_id).stale)
    assert.matches("file changed", deps.notifications[#deps.notifications].message, nil, true)

    deps.locator.stale = false
    deps.windows[deps.origin_win].valid = false
    assert.is_false(session:activate_row({ kind = "location", owner_id = result_id }))
    assert.equals(deps.root_id, session:state().flow.current_node_id)
  end)

  it("normalizes note input and rejects cancelled, duplicate, stale, and superseded callbacks", function()
    local session, deps = new_session()
    assert.is_true(session:open())

    assert.is_true(session:edit_note({ kind = "note", owner_id = deps.root_id }))
    assert.is_nil(deps.input_opts.default)
    local first_callback = deps.input_callback
    assert.is_true(session:edit_note({ kind = "location", owner_id = deps.root_id }))
    local second_callback = deps.input_callback
    first_callback("old value")
    assert.is_nil(session:state().flow.root.note)
    second_callback("  important\r\nfor auth  ")
    assert.equals("important for auth", session:state().flow.root.note)

    local renders = deps.sidebar.render_count
    assert.is_true(session:edit_note({ kind = "location", owner_id = deps.root_id }))
    assert.equals("important for auth", deps.input_opts.default)
    deps.input_callback("important for auth")
    assert.equals(renders, deps.sidebar.render_count)

    assert.is_true(session:edit_note({ kind = "location", owner_id = deps.root_id }))
    deps.input_callback(nil)
    assert.equals("important for auth", session:state().flow.root.note)
    assert.is_true(session:edit_note({ kind = "location", owner_id = deps.root_id }))
    deps.input_callback(" \n ")
    assert.is_nil(session:state().flow.root.note)

    assert.is_true(session:edit_note({ kind = "location", owner_id = deps.root_id }))
    local late = deps.input_callback
    session:close("command")
    late("too late")
    assert.is_nil(session:state().flow.root.note)
  end)

  it("serializes dirty close decisions and remounts after cancel", function()
    local session, deps = new_session()
    assert.is_true(session:open())
    assert.is_true(session:state().flow:set_note(deps.root_id, "dirty"))
    deps.sidebar:unmount({ owned = false })

    assert.is_true(session:close("external_popup"))
    assert.equals("deciding", session:state().phase)
    assert.same({ "Save", "Discard", "Cancel" }, deps.select_items)
    local decision = deps.select_callback
    local list_calls = #deps.store.list_calls
    assert.is_false(session:close("command"))
    assert.is_nil(session:load())
    assert.equals(list_calls, #deps.store.list_calls)
    assert.equals(decision, deps.select_callback)

    decision("Cancel", 3)
    assert.equals("active", session:state().phase)
    assert.is_true(session:is_active())
    assert.is_true(session:state().flow:is_dirty())
    assert.is_true(deps.sidebar:is_mounted())
  end)

  it("saves synchronously and resumes the winning dirty-close intent", function()
    local session, deps = new_session()
    assert.is_true(session:open())
    assert.is_true(session:state().flow:set_note(deps.root_id, "persist me"))

    assert.is_true(session:close("command"))
    deps.select_callback("Save", 1)
    assert.equals(1, #deps.store.save_calls)
    assert.equals("closed", session:state().phase)
    assert.is_false(session:state().flow:is_dirty())
  end)

  it("keeps a dirty session open and remounts when save fails", function()
    local session, deps = new_session()
    assert.is_true(session:open())
    assert.is_true(session:state().flow:set_note(deps.root_id, "persist me"))
    deps.store.save_error = "disk full"
    deps.sidebar:unmount({ owned = false })

    assert.is_true(session:close("external_popup"))
    deps.select_callback("Save", 1)
    assert.equals("active", session:state().phase)
    assert.is_true(session:state().flow:is_dirty())
    assert.is_true(deps.sidebar:is_mounted())
    assert.matches("disk full", deps.notifications[#deps.notifications].message, nil, true)
  end)

  it("lets a completion after explicit save begin a new dirty epoch", function()
    local session, deps = new_session()
    assert.is_true(session:open())
    session:run_action("definition")
    local context = deps.lsp.starts[1].context

    assert.is_true(session:save())
    assert.is_false(session:state().flow:is_dirty())
    deps.lsp:complete(1, {
      status = "success",
      action = { method = "textDocument/definition", label = "definition", presentation = "jump_or_list" },
      method = "textDocument/definition",
      label = "definition",
      origin_node_id = context.origin_node_id,
      items = {},
      locations = {},
      failures = {},
    })
    assert.is_true(session:state().flow:is_dirty())
    assert.equals(1, #session:state().flow.root.actions)
  end)

  it("atomically activates a selected flow when no session exists", function()
    local session, deps = new_session()
    local loaded = Fixtures.new_flow()
    local entry =
      { path = "/project/.voyager/flows/main.json", name = "main", display_path = "lua/main.lua", updated_at = "now" }
    deps.store.entries = { entry }
    deps.store.load_result = loaded

    assert.is_true(session:load())
    assert.same({ deps.project_root }, deps.store.list_calls)
    deps.select_callback(entry, 1)

    assert.same({ { entry, deps.project_root } }, deps.store.load_calls)
    assert.is_true(session:is_active())
    assert.equals(loaded, session:state().flow)
    assert.equals(deps.project_root, session:state().project_root)
    assert.equals(1, #deps.sidebar.mount_calls)
    assert.is_false(deps.sidebar.mount_calls[1].focus)
    assert.same({ deps.origin_buf }, deps.keymaps.applied_buffers)
    assert.equals(loaded.current_node_id, session:state().flow.current_node_id)
  end)

  it("leaves an inactive controller untouched when a selected flow cannot load", function()
    local session, deps = new_session()
    local entry =
      { path = "/project/.voyager/flows/main.json", name = "main", display_path = "lua/main.lua", updated_at = "now" }
    deps.store.entries = { entry }
    deps.store.load_error = "flow changed after listing"

    assert.is_true(session:load())
    deps.select_callback(entry, 1)
    assert.is_false(session:is_active())
    assert.equals(0, #deps.sidebar.mount_calls)
    assert.same({}, deps.keymaps.applied_buffers)
    assert.matches("flow changed after listing", deps.notifications[#deps.notifications].message, nil, true)
  end)

  it("retires an active flow only after the loaded sidebar mounts", function()
    local session, deps = new_session()
    assert.is_true(session:open())
    session:run_action("definition")
    local original = session:state().flow
    local generation = session:state().generation
    local old_sidebar = deps.sidebar
    local old_keymaps = deps.keymaps
    local old_presenter = deps.presenter
    local old_handle = deps.lsp.handles[1]
    local loaded = Fixtures.new_flow()
    local entry =
      { path = "/project/.voyager/flows/main.json", name = "main", display_path = "lua/main.lua", updated_at = "now" }
    deps.store.entries = { entry }
    deps.store.load_result = loaded
    local loaded_sidebar = deps:new_sidebar()
    local loaded_keymaps = deps:new_keymaps()
    local loaded_presenter = deps:new_presenter()
    deps.next_sidebar = loaded_sidebar
    deps.next_keymaps = loaded_keymaps
    deps.next_lsp = deps:new_lsp()
    deps.next_presenter = loaded_presenter
    loaded_sidebar.on_mount = function()
      assert.equals(original, session:state().flow)
      assert.equals(generation, session:state().generation)
      assert.equals(0, #old_handle.cancel_calls)
      assert.equals(0, old_presenter.invalidate_calls)
      assert.same({}, old_keymaps.restored_generations)
    end

    deps.sidebar:focus()
    assert.is_true(session:load())
    deps.select_callback(entry, 1)
    assert.equals(loaded, session:state().flow)
    assert.equals(generation + 1, session:state().generation)
    assert.equals(loaded_sidebar, session:state().sidebar)
    assert.same({ "load" }, old_handle.cancel_calls)
    assert.equals(1, old_presenter.invalidate_calls)
    assert.same({ generation }, old_keymaps.restored_generations)
    assert.same({ deps.origin_buf }, loaded_keymaps.applied_buffers)
    assert.is_false(old_sidebar:is_mounted())
  end)

  it("rolls back the old popup when a loaded flow cannot mount", function()
    local session, deps = new_session()
    assert.is_true(session:open())
    local original = session:state().flow
    local generation = session:state().generation
    assert.is_true(original:set_note(deps.root_id, "dirty"))
    local entry =
      { path = "/project/.voyager/flows/main.json", name = "main", display_path = "lua/main.lua", updated_at = "now" }
    deps.store.entries = { entry }
    deps.store.load_result = Fixtures.new_flow()
    local loaded_sidebar = deps:new_sidebar()
    loaded_sidebar.mount_result = false
    loaded_sidebar.mount_error = "editor must be at least 24 columns wide"
    deps.next_sidebar = loaded_sidebar
    deps.next_keymaps = deps:new_keymaps()
    deps.next_lsp = deps:new_lsp()
    deps.next_presenter = deps:new_presenter()
    local old_mounts = #deps.sidebar.mount_calls

    assert.is_true(session:load())
    local picker = deps.select_callback
    picker(entry, 1)
    deps.select_callback("Discard", 2)

    assert.equals(original, session:state().flow)
    assert.equals(generation, session:state().generation)
    assert.equals("active", session:state().phase)
    assert.equals(old_mounts + 1, #deps.sidebar.mount_calls)
    assert.matches("24 columns", deps.notifications[#deps.notifications].message, nil, true)
  end)

  it("repairs a stale loaded current node to the root and keeps the repair dirty", function()
    local session, deps = new_session()
    local loaded = Fixtures.new_flow()
    local result = Fixtures.location("lua/old.lua", 0)
    local commit = loaded:commit_navigation({
      origin_node_id = loaded.root.id,
      method = "textDocument/definition",
      label = "definition",
      locations = { result },
    })
    assert.is_true(loaded:set_current(commit.node_id_by_identity[result.identity]))
    deps.store:save(loaded)
    deps.store.save_calls = {}
    local entry =
      { path = "/project/.voyager/flows/main.json", name = "main", display_path = "lua/main.lua", updated_at = "now" }
    deps.store.entries = { entry }
    deps.store.load_result = loaded
    deps.locator.stale = true

    assert.is_true(session:load())
    deps.select_callback(entry, 1)
    assert.equals(loaded.root.id, session:state().flow.current_node_id)
    assert.is_true(session:state().flow:is_dirty())
  end)

  it("reports skipped entries and an empty saved-flow list without opening a picker", function()
    local session, deps = new_session()
    deps.store.warnings = { "Voyager: skipped broken.json: invalid JSON" }
    assert.is_nil(session:load())
    assert.is_nil(deps.select_callback)
    assert.equals(2, #deps.notifications)
    assert.matches("invalid JSON", deps.notifications[1].message, nil, true)
    assert.matches("no saved flows", deps.notifications[2].message, nil, true)
  end)

  it("ignores cancelled and stale saved-flow picker callbacks", function()
    local session, deps = new_session()
    local entry =
      { path = "/project/.voyager/flows/main.json", name = "main", display_path = "lua/main.lua", updated_at = "now" }
    deps.store.entries = { entry }
    deps.store.load_result = Fixtures.new_flow()

    assert.is_true(session:load())
    deps.select_callback(nil)
    assert.is_false(session:is_active())
    assert.equals(0, #deps.store.load_calls)

    assert.is_true(session:load())
    local stale_picker = deps.select_callback
    assert.is_true(session:open())
    stale_picker(entry, 1)
    assert.equals(0, #deps.store.load_calls)
    assert.equals(deps.root_id, session:state().flow.root.id)
  end)

  it("keeps a valid saved current clean and jumps it without creating a split", function()
    local session, deps = new_session()
    local loaded = Fixtures.new_flow()
    local result = Fixtures.location("lua/saved.lua", 4)
    local commit = loaded:commit_navigation({
      origin_node_id = loaded.root.id,
      method = "textDocument/definition",
      label = "definition",
      locations = { result },
    })
    local saved_id = commit.node_id_by_identity[result.identity]
    assert.is_true(loaded:set_current(saved_id))
    deps.store:save(loaded)
    deps.store.save_calls = {}
    local entry =
      { path = "/project/.voyager/flows/main.json", name = "main", display_path = "lua/main.lua", updated_at = "now" }
    deps.store.entries = { entry }
    deps.store.load_result = loaded
    local windows = vim.tbl_count(deps.windows)

    assert.is_true(session:load())
    deps.select_callback(entry, 1)
    assert.equals(saved_id, session:state().flow.current_node_id)
    assert.is_false(session:state().flow:is_dirty())
    assert.same({ 5, 0 }, deps.windows[deps.origin_win].cursor)
    assert.equals(windows + 1, vim.tbl_count(deps.windows))
  end)

  it("preserves a saved logical current when no source window is available", function()
    local session, deps = new_session()
    local loaded = Fixtures.new_flow()
    local result = Fixtures.location("lua/saved.lua", 4)
    local commit = loaded:commit_navigation({
      origin_node_id = loaded.root.id,
      method = "textDocument/definition",
      label = "definition",
      locations = { result },
    })
    local saved_id = commit.node_id_by_identity[result.identity]
    assert.is_true(loaded:set_current(saved_id))
    deps.store:save(loaded)
    deps.store.save_calls = {}
    local entry =
      { path = "/project/.voyager/flows/main.json", name = "main", display_path = "lua/main.lua", updated_at = "now" }
    deps.store.entries = { entry }
    deps.store.load_result = loaded
    deps.windows[deps.origin_win].valid = false

    assert.is_true(session:load())
    deps.select_callback(entry, 1)
    assert.equals(saved_id, session:state().flow.current_node_id)
    assert.is_false(session:state().flow:is_dirty())
    assert.matches("no eligible source window", deps.notifications[#deps.notifications].message, nil, true)
  end)

  it("rejects note and dirty-decision callbacks after loaded-flow replacement or shutdown", function()
    local session, deps = new_session()
    assert.is_true(session:open())
    assert.is_true(session:edit_note({ kind = "location", owner_id = deps.root_id }))
    local late_note = deps.input_callback
    local entry =
      { path = "/project/.voyager/flows/main.json", name = "main", display_path = "lua/main.lua", updated_at = "now" }
    deps.store.entries = { entry }
    deps.store.load_result = Fixtures.new_flow()
    deps.next_sidebar = deps:new_sidebar()
    deps.next_keymaps = deps:new_keymaps()
    deps.next_lsp = deps:new_lsp()
    deps.next_presenter = deps:new_presenter()

    assert.is_true(session:load())
    deps.select_callback(entry, 1)
    late_note("late note")
    assert.is_nil(session:state().flow.root.note)

    assert.is_true(session:state().flow:set_note(session:state().flow.root.id, "dirty"))
    assert.is_true(session:close("command"))
    local late_decision = deps.select_callback
    session:shutdown()
    late_decision("Discard", 2)
    assert.equals("closed", session:state().phase)
  end)

  it("closes cleanly once and restores focus only from Voyager UI", function()
    local session, deps = new_session()
    assert.is_true(session:open())
    local generation = session:state().generation
    local request = { cancel_calls = {} }
    function request:cancel(reason)
      table.insert(self.cancel_calls, reason)
    end
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
      keymaps = function()
        return deps.keymaps
      end,
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
    local session = Session.native(function()
      return vim.deepcopy(deps.config)
    end, deps.runtime, factories)
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
    session.activate_row = function(_, value)
      calls.activate = value
    end
    session.edit_note = function(_, value)
      calls.note = value
    end
    session.toggle_row = function(_, value)
      calls.toggle = value
    end
    session.save = function()
      calls.save = true
    end
    session.load = function()
      calls.load = true
    end
    session.close = function(_, source)
      calls.close = source
    end
    session.set_current = function(_, node_id)
      calls.current = node_id
    end
    session.choose_jump_window = function()
      return deps.origin_win
    end

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
