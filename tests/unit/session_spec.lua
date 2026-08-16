local FakeSessionDeps = require("tests.helpers.fake_session_deps")
local Fixtures = require("tests.helpers.flow")
local Locator = require("voyager.locator")
local Actions = require("voyager.lsp.actions")
local Session = require("voyager.session")
local Sidebar = require("voyager.sidebar")

local function new_session(overrides)
  local deps = FakeSessionDeps.new(overrides)
  return Session.new(deps:session_options()), deps
end

-- Automatic graph creation is covered separately. Lifecycle cases cancel its
-- queued work so they can isolate the operation under test.
local function open_with_flow(session)
  assert.is_true(session:open())
  if session:state().graph_build then
    assert.is_true(session:_cancel_graph_build({ dismiss = true, render = false, reason = "test isolation" }))
  end
  return true
end

local function call_location(location, semantic_locator)
  local value = vim.deepcopy(location)
  value.query_anchor = {
    locator = vim.deepcopy(semantic_locator or value.locator),
    range = vim.deepcopy(value.range),
    line_text = "semantic symbol",
  }
  value.identity = Locator.location_key(value)
  return value
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
      assert.same({}, deps.autocmd_calls)
    end
  end)

  it("atomically opens a clean flow from a normal named buffer", function()
    local session, deps = new_session()
    open_with_flow(session)
    assert.is_true(session:is_active())
    assert.equals("active", session:state().phase)
    assert.equals(deps.origin_win, session:state().source_windows[1])
    assert.equals(deps.root_id, session:state().flow.current_node_id)
    assert.is_false(session:state().flow:is_dirty())
    assert.is_false(deps.sidebar.mount_calls[1].focus)
    -- one root render followed by one automatic-build render
    assert.equals(2, deps.sidebar.render_count)
    assert.equals(7, #deps.autocmd_calls)
  end)

  it("atomically rejects a dependency seed and fails closed on boundary errors", function()
    local session, deps = new_session({ buffer_name = "/project/node_modules/pkg/index.lua" })
    deps.locator.is_project_location = function(_, location)
      return not location.locator.path:find("node_modules", 1, true)
    end

    assert.is_nil(session:open())
    assert.is_false(session:is_active())
    assert.equals(0, #deps.lsp.starts)
    assert.same({ { owned = true } }, deps.sidebar.unmount_calls)
    assert.matches("outside project files", deps.notifications[#deps.notifications].message, nil, true)

    session, deps = new_session()
    deps.locator.is_project_location = function()
      error("realpath failed")
    end
    assert.is_nil(session:open())
    assert.is_false(session:is_active())
    assert.matches("outside project files", deps.notifications[#deps.notifications].message, nil, true)
  end)

  it("captures the cursor root and schedules both call directions on open", function()
    local session, deps = new_session()
    assert.is_true(session:open())
    assert.is_true(session:is_active())
    local flow = session:state().flow
    assert.is_table(flow)
    assert.equals("main", flow.root.location.symbol)
    assert.equals(flow.root.id, flow.current_node_id)
    assert.is_table(session:state().graph_build)
    assert.is_nil(deps.autocmds.LspRequest)

    deps:flush_scheduled()
    assert.same({ "incoming_calls", "outgoing_calls" }, {
      deps.lsp.starts[1].action_name,
      deps.lsp.starts[2].action_name,
    })
    assert.equals(flow.root.id, deps.lsp.starts[1].context.origin_node_id)
    assert.equals(flow.root.id, deps.lsp.starts[2].context.origin_node_id)

    assert.equals(1, #deps.symbols.resolve_calls)
    assert.equals(flow.root.id, deps.symbols.resolve_calls[1].requests[1].node_id)
  end)

  it("closes a clean session without prompting and toggles cleanly", function()
    local session, deps = new_session()
    assert.is_true(session:open())
    assert.is_true(session:close("command"))
    assert.is_false(session:is_active())
    assert.is_nil(deps.select_callback)
  end)

  it("keeps environment syntax literal in editor-derived project roots", function()
    local session, deps = new_session({ buffer_name = "/project/$HOME/lua/main.lua" })
    deps.clients = {}
    deps.runtime.find_root = function()
      return "/project/$HOME"
    end

    open_with_flow(session)
    assert.equals("/project/$HOME", session:state().project_root)
    assert.equals("lua/main.lua", session:state().flow.root.location.locator.path)
  end)

  it("joins project locations beneath the filesystem root with one slash", function()
    local session, deps = new_session()
    open_with_flow(session)
    local state = session:state()
    state.project_root = "/"
    assert.is_table(session:show_callers({ kind = "location", owner_id = state.flow.root.id }))
    assert.equals("file:///lua/main.lua", deps.lsp.starts[1].context.stored_position.uri)
  end)

  it("does not use a filesystem-wide LSP root as the project boundary", function()
    local session, deps = new_session()
    deps.clients[1].config.root_dir = "/"

    open_with_flow(session)

    assert.equals("/project", session:state().project_root)

    session:close("test")
    session, deps = new_session()
    deps.clients[1].config.root_dir = "/"
    deps.runtime.find_root = function()
      return "/"
    end
    deps.runtime.cwd = function()
      return "/"
    end

    open_with_flow(session)
    assert.equals("/project/lua", session:state().project_root)
  end)

  it("does not publish a session when the initial sidebar cannot mount", function()
    local session, deps = new_session()
    deps.sidebar.mount_result = false
    deps.sidebar.mount_error = "editor must be at least 24 columns wide"
    assert.is_nil(session:open())
    assert.is_false(session:is_active())
    assert.same({}, deps.autocmd_calls)
    assert.same({ { owned = true } }, deps.sidebar.unmount_calls)
    assert.matches("24 columns", deps.notifications[#deps.notifications].message)
  end)

  it("accepts a named unsaved buffer and tears down after entropy failure", function()
    local session, deps = new_session({ buffer_name = "/project/lua/new.lua" })
    open_with_flow(session)
    assert.equals("new.lua", session:state().flow.root.location.locator.path:match("([^/]+)$"))

    session, deps = new_session()
    deps.random_error = "entropy unavailable"
    assert.is_nil(session:open())
    assert.is_false(session:is_active())
    assert.same({ { owned = true } }, deps.sidebar.unmount_calls)
    assert.matches("entropy unavailable", deps.notifications[1].message, nil, true)
  end)

  it("keeps an existing session and focuses or remounts its popup", function()
    local session, deps = new_session()
    open_with_flow(session)
    local flow = session:state().flow
    open_with_flow(session)
    assert.equals(flow, session:state().flow)
    assert.equals(1, #deps.sidebar.mount_calls)
    assert.equals(1, deps.sidebar.focus_count)

    deps.sidebar.mounted = false
    local renders = deps.sidebar.render_count
    assert.is_true(session:focus())
    assert.is_true(deps.sidebar.remount_calls[#deps.sidebar.remount_calls].focus)
    assert.equals(renders + 1, deps.sidebar.render_count)

    deps.sidebar.mounted = false
    deps.sidebar.remount_result = false
    deps.sidebar.remount_error = "editor must be at least 24 columns wide"
    assert.is_nil(session:focus())
    assert.is_true(session:is_active())
    assert.matches("24 columns", deps.notifications[#deps.notifications].message)
  end)

  it("remounts without focus across tabs and resize validity changes", function()
    local session, deps = new_session()
    open_with_flow(session)
    local renders = deps.sidebar.render_count
    deps:trigger("TabEnter")
    assert.is_false(deps.sidebar.remount_calls[#deps.sidebar.remount_calls].focus)
    assert.equals(renders + 1, deps.sidebar.render_count)

    deps.sidebar.remount_result = false
    deps.sidebar.remount_error = "too small"
    deps:trigger("VimResized")
    assert.is_false(deps.sidebar:is_mounted())
    assert.is_true(session:is_active())
    assert.equals(renders + 1, deps.sidebar.render_count)

    deps.sidebar.remount_result = true
    deps:trigger("VimResized")
    assert.is_true(deps.sidebar:is_mounted())
    assert.is_false(deps.sidebar.remount_calls[#deps.sidebar.remount_calls].focus)
    assert.equals(renders + 2, deps.sidebar.render_count)
  end)

  it("tracks recent source windows, evicts closed candidates, and never creates a split", function()
    local session, deps = new_session()
    open_with_flow(session)
    deps:add_buffer(12, "/project/lua/other.lua")
    deps:add_window(22, 12)
    deps.current_win_id = 22
    deps:trigger("WinEnter", { buf = 12 })
    assert.equals(22, session:state().source_windows[1])
    assert.equals(22, session:choose_jump_window())

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

  it("tracks the active tree symbol from ordinary source navigation", function()
    local session, deps = new_session()
    open_with_flow(session)
    local state = session:state()
    local location = Fixtures.location("lua/callsite.lua", 4, "Service.save")
    location.query_anchor = {
      locator = { kind = "project", path = "lua/service.lua" },
      range = {
        start = { line = 2, character = 0 },
        ["end"] = { line = 2, character = 4 },
      },
      line_text = "save()",
    }
    location.identity = Locator.location_key(location)
    local commit = state.flow:commit_navigation({
      origin_node_id = state.flow.root.id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { location },
    })
    local child_id = assert(commit.node_id_by_identity[location.identity])

    deps:add_buffer(12, "/project/lua/service.lua", { lines = { "one", "two", "save()" } })
    deps:add_window(22, 12)
    deps.windows[22].cursor = { 3, 1 }
    deps.current_win_id = 22
    local renders = deps.sidebar.render_count
    deps:trigger("BufEnter", { buf = 12 })
    assert.equals(child_id, state.flow.current_node_id)
    assert.equals(renders + 1, deps.sidebar.render_count)

    deps.current_win_id = deps.origin_win
    deps:trigger("WinEnter", { buf = deps.origin_buf })
    assert.equals(state.flow.root.id, state.flow.current_node_id)
  end)

  it("prefers a semantic anchor over another node's overlapping display range", function()
    local session, deps = new_session()
    open_with_flow(session)
    local state = session:state()
    local display_match = Fixtures.location("lua/service.lua", 2, "display match")
    display_match.query_anchor = {
      locator = { kind = "project", path = "lua/other.lua" },
      range = vim.deepcopy(display_match.range),
      line_text = "other()",
    }
    display_match.identity = Locator.location_key(display_match)
    local semantic_match = Fixtures.location("lua/callsite.lua", 4, "semantic match")
    semantic_match.query_anchor = {
      locator = { kind = "project", path = "lua/service.lua" },
      range = vim.deepcopy(display_match.range),
      line_text = "save()",
    }
    semantic_match.identity = Locator.location_key(semantic_match)
    local commit = state.flow:commit_navigation({
      origin_node_id = state.flow.root.id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { display_match, semantic_match },
    })
    local display_id = assert(commit.node_id_by_identity[display_match.identity])
    local semantic_id = assert(commit.node_id_by_identity[semantic_match.identity])
    assert.is_true(state.flow:set_current(display_id))

    deps:add_buffer(12, "/project/lua/service.lua", { lines = { "one", "two", "save()" } })
    deps:add_window(22, 12)
    deps.windows[22].cursor = { 3, 1 }
    deps.current_win_id = 22
    deps:trigger("BufEnter", { buf = 12 })

    assert.equals(semantic_id, state.flow.current_node_id)
  end)

  it("keeps a direct symbol active ahead of a call row anchored to it", function()
    local session, deps = new_session()
    open_with_flow(session)
    local state = session:state()
    local call = Fixtures.location("lua/callsite.lua", 4, "main")
    call.query_anchor = {
      locator = vim.deepcopy(state.flow.root.location.locator),
      range = vim.deepcopy(state.flow.root.location.range),
      line_text = state.flow.root.location.context,
    }
    call.identity = Locator.location_key(call)
    local commit = state.flow:commit_navigation({
      origin_node_id = state.flow.root.id,
      method = "callHierarchy/incomingCalls",
      label = "callers",
      locations = { call },
    })
    local call_id = assert(commit.node_id_by_identity[call.identity])
    assert.is_true(state.flow:set_current(call_id))

    deps.current_win_id = deps.origin_win
    deps:trigger("CursorMoved", { buf = deps.origin_buf })

    assert.equals(state.flow.root.id, state.flow.current_node_id)
  end)

  it("does not observe editor LSP requests", function()
    local session, deps = new_session()
    assert.is_true(session:open())
    assert.is_nil(deps.autocmds.LspRequest)
    deps:flush_scheduled()
    assert.equals(2, #deps.lsp.starts)
    assert.same({ "incoming_calls", "outgoing_calls" }, {
      deps.lsp.starts[1].action_name,
      deps.lsp.starts[2].action_name,
    })
  end)

  it("deletes rows, clears notes through delete, and refuses the root", function()
    local session, deps = new_session()
    open_with_flow(session)
    local site = Fixtures.location("lua/site.lua", 1, "site")
    local commit = session:state().flow:commit_navigation({
      origin_node_id = deps.root_id,
      method = "textDocument/references",
      label = "references",
      locations = { site },
    })
    local site_id = commit.node_id_by_identity[site.identity]
    assert.is_true(session:state().flow:set_note(site_id, "keep"))

    assert.is_true(session:delete_row({ kind = "note", owner_id = site_id }))
    assert.is_nil(session:state().flow:location(site_id).note)

    assert.is_false(session:delete_row({ kind = "location", owner_id = deps.root_id }))
    assert.matches("root cannot be deleted", deps.notifications[#deps.notifications].message, nil, true)

    local renders = deps.sidebar.render_count
    assert.is_true(session:delete_row({ kind = "location", owner_id = site_id }))
    assert.is_nil(session:state().flow:find(site_id))
    assert.equals(renders + 1, deps.sidebar.render_count)
    assert.is_nil(session:state().destination_claim)
  end)

  it("unlinks one displayed location occurrence without deleting its canonical node", function()
    local session, deps = new_session()
    open_with_flow(session)
    local state = session:state()
    local first = Fixtures.location("lua/first.lua", 1, "first")
    local second = Fixtures.location("lua/second.lua", 2, "second")
    local branches = state.flow:commit_navigation({
      origin_node_id = deps.root_id,
      method = "textDocument/implementation",
      label = "implementations",
      locations = { first, second },
    })
    local first_id = branches.node_id_by_identity[first.identity]
    local second_id = branches.node_id_by_identity[second.identity]
    local cross_link = state.flow:commit_navigation({
      origin_node_id = first_id,
      method = "callHierarchy/outgoingCalls",
      label = "calls",
      locations = { second },
    })
    assert.is_true(state.flow:set_note(second_id, "keep"))
    assert.is_true(state.flow:set_current(second_id))
    state.destination_claim = { sentinel = true }

    assert.is_true(session:delete_row({
      kind = "location",
      owner_id = second_id,
      context_location_id = second_id,
      action_id = branches.action_id,
    }))

    assert.same({ first_id }, state.flow:action_target_ids(branches.action_id))
    assert.same({ second_id }, state.flow:action_target_ids(cross_link.action_id))
    assert.equals("keep", state.flow:location(second_id).note)
    assert.equals(second_id, state.flow.current_node_id)
    assert.is_nil(state.destination_claim)
  end)

  it("deletes a manual relation and removes its archive after the last history row", function()
    local session, deps = new_session()
    open_with_flow(session)
    local state = session:state()
    local manual = Fixtures.location("lua/manual.lua", 1, "manual")
    local commit = state.flow:commit_navigation({
      origin_node_id = deps.root_id,
      manual_location = manual,
      method = "textDocument/definition",
      label = "definition",
      locations = {},
    })
    local manual_id = commit.effective_origin_id
    local manual_action = assert(state.flow:action_for(deps.root_id, "voyager/manual"))

    assert.is_true(session:delete_row({ kind = "action", owner_id = manual_action.id }))
    assert.is_nil(state.flow:action_for(deps.root_id, "voyager/manual"))
    local archive = assert(state.flow:action_for(deps.root_id, "voyager/archive"))
    assert.same({}, archive.target_ids)
    assert.equals(manual_id, archive.results[1].id)
    assert.is_table(state.flow:location(manual_id))

    assert.is_true(session:delete_row({ kind = "location", owner_id = manual_id, detached = true }))
    assert.is_nil(state.flow:location(manual_id))
    assert.is_nil(state.flow:action_for(deps.root_id, "voyager/archive"))
  end)

  it("jumps and records a picked action from a sidebar row", function()
    local session, deps = new_session()
    open_with_flow(session)
    local site = Fixtures.location("lua/site.lua", 0, "site")
    local commit = session:state().flow:commit_navigation({
      origin_node_id = deps.root_id,
      method = "textDocument/references",
      label = "references",
      locations = { site },
    })
    local site_id = commit.node_id_by_identity[site.identity]
    deps:add_buffer(71, "/project/lua/site.lua", { lines = { "site here" } })
    deps.locator.open_target_result = { bufnr = 71, row = 1, col = 0 }
    deps.cursor_word = "site"
    deps.cursor_word_start = 0
    deps.cursor_word_end = 4

    assert.is_true(session:run_action_for_row({ kind = "location", owner_id = site_id }))
    assert.equals(site_id, session:state().flow.current_node_id)
    assert.equals("Voyager action", deps.select_opts.prompt)
    deps.select_callback("references", 3)
    assert.equals(1, #deps.lsp.starts)
    assert.equals("references", deps.lsp.starts[1].action_name)
    assert.equals(site_id, deps.lsp.starts[1].context.origin_node_id)
  end)

  it("previews a location beside the sidebar and rejects other rows", function()
    local session, deps = new_session()
    open_with_flow(session)
    local site = Fixtures.location("lua/site.lua", 1, "site")
    local commit = session:state().flow:commit_navigation({
      origin_node_id = deps.root_id,
      method = "textDocument/references",
      label = "references",
      locations = { site },
    })
    local site_id = commit.node_id_by_identity[site.identity]
    deps.locator.source_lines = { "l1", "l2", "l3", "l4", "l5" }

    assert.is_true(session:preview_row({ kind = "location", owner_id = site_id }))
    local preview = deps.sidebar.preview_calls[1]
    assert.same({ "l1", "l2", "l3", "l4", "l5" }, preview.lines)
    assert.equals(2, preview.focus_line)
    assert.equals("lua", preview.filetype)
    assert.matches("site", preview.title, nil, true)

    assert.is_nil(session:preview_row({ kind = "action", owner_id = deps.root_id }))
    assert.matches("cannot preview", deps.notifications[#deps.notifications].message, nil, true)

    deps.locator.source_lines = false
    assert.is_nil(session:preview_row({ kind = "location", owner_id = site_id }))
    assert.matches("unavailable", deps.notifications[#deps.notifications].message, nil, true)
  end)

  it("follows the cursor with the preview and hides it on non-location rows", function()
    local session, deps = new_session()
    open_with_flow(session)
    local site = Fixtures.location("lua/site.lua", 1, "site")
    local commit = session:state().flow:commit_navigation({
      origin_node_id = deps.root_id,
      method = "textDocument/references",
      label = "usages",
      locations = { site },
    })
    local site_id = commit.node_id_by_identity[site.identity]
    deps.locator.source_lines = { "l1", "l2", "l3" }

    local closes = 0
    deps.sidebar.close_preview = function()
      closes = closes + 1
    end

    assert.is_true(session:follow_preview({ kind = "location", owner_id = site_id }))
    local preview = deps.sidebar.preview_calls[#deps.sidebar.preview_calls]
    assert.equals(site_id, preview.key)
    assert.equals(2, preview.focus_line)

    session:follow_preview({ kind = "action", owner_id = commit.action_id })
    assert.equals(1, closes)
    session:follow_preview(nil)
    assert.equals(2, closes)

    -- unavailable source renders a message float instead of a warning
    deps.locator.source_lines = false
    local notifications = #deps.notifications
    assert.is_true(session:follow_preview({ kind = "location", owner_id = site_id }))
    local unavailable = deps.sidebar.preview_calls[#deps.sidebar.preview_calls]
    assert.matches("unavailable", unavailable.lines[1], nil, true)
    assert.equals(notifications, #deps.notifications)
  end)

  it("exports resolvable locations to the quickfix list", function()
    local session, deps = new_session()
    open_with_flow(session)
    local site = Fixtures.location("lua/site.lua", 1, "site", "local site = 1")
    local virtual = Fixtures.location("unused", 2, "virtual")
    virtual.locator = { kind = "uri", uri = "jdt://contents/Virtual.class" }
    virtual.identity = require("voyager.locator").location_key(virtual)
    session:state().flow:commit_navigation({
      origin_node_id = deps.root_id,
      method = "textDocument/references",
      label = "references",
      locations = { site, virtual },
    })

    assert.equals(2, session:export())
    assert.equals("Voyager: main", deps.quickfix.title)
    assert.equals(2, #deps.quickfix.items)
    assert.equals("/project/lua/site.lua", deps.quickfix.items[2].filename)
    assert.equals(2, deps.quickfix.items[2].lnum)
    assert.equals("local site = 1", deps.quickfix.items[2].text)
    assert.matches("exported 2 locations", deps.notifications[#deps.notifications].message, nil, true)
    assert.matches("1 unresolvable skipped", deps.notifications[#deps.notifications].message, nil, true)
  end)

  it("collapses and expands every action and keeps focus on stay-jumps", function()
    local session, deps = new_session()
    open_with_flow(session)
    local site = Fixtures.location("lua/site.lua", 1, "site")
    local commit = session:state().flow:commit_navigation({
      origin_node_id = deps.root_id,
      method = "textDocument/references",
      label = "references",
      locations = { site },
    })
    local site_id = commit.node_id_by_identity[site.identity]

    assert.is_true(session:set_all_collapsed(true))
    assert.is_true(session:state().flow:find(commit.action_id).collapsed)
    assert.is_true(session:set_all_collapsed(false))
    assert.is_false(session:state().flow:find(commit.action_id).collapsed)

    deps.sidebar.mounted = true
    assert.is_true(session:activate_row({ kind = "location", owner_id = site_id }, { stay = true }))
    assert.equals(deps.sidebar.winid, deps.current_win_id)
    assert.equals(1, #deps.flashes)
    assert.equals(deps.origin_buf, deps.flashes[1].bufnr)
  end)

  it("autosaves dirty flows on close and shutdown when enabled", function()
    local session, deps = new_session()
    deps.config.storage.autosave = true
    open_with_flow(session)
    assert.is_true(session:state().flow:set_note(deps.root_id, "dirty"))
    assert.is_true(session:close("command"))
    assert.equals(1, #deps.store.save_calls)
    assert.is_nil(deps.select_callback)
    assert.is_false(session:is_active())

    session, deps = new_session()
    deps.config.storage.autosave = true
    open_with_flow(session)
    assert.is_true(session:state().flow:set_note(deps.root_id, "dirty"))
    deps.store.save_error = "disk full"
    session:close("command")
    assert.is_function(deps.select_callback)
    deps.select_callback("Discard", 2)
    assert.is_false(session:is_active())

    session, deps = new_session()
    deps.config.storage.autosave = true
    open_with_flow(session)
    assert.is_true(session:state().flow:set_note(deps.root_id, "dirty"))
    session:shutdown()
    assert.equals(1, #deps.store.save_calls)
    assert.is_false(session:is_active())
  end)

  it("dispatches typed rows without confusing locations, actions, and notes", function()
    local session, deps = new_session()
    open_with_flow(session)
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
    open_with_flow(session)
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
    open_with_flow(session)

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
    open_with_flow(session)
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

  it("recovers when the dirty-decision UI provider throws", function()
    local session, deps = new_session()
    open_with_flow(session)
    assert.is_true(session:state().flow:set_note(deps.root_id, "dirty"))
    deps.sidebar:unmount({ owned = false })
    deps.select_error = "picker exploded"

    assert.has_no.errors(function()
      assert.is_false(session:close("command"))
    end)

    assert.equals("active", session:state().phase)
    assert.is_true(session:state().flow:is_dirty())
    assert.is_true(deps.sidebar:is_mounted())
    assert.matches("picker exploded", deps.notifications[#deps.notifications].message, nil, true)
  end)

  it("saves synchronously and resumes the winning dirty-close intent", function()
    local session, deps = new_session()
    open_with_flow(session)
    assert.is_true(session:state().flow:set_note(deps.root_id, "persist me"))

    assert.is_true(session:close("command"))
    deps.select_callback("Save", 1)
    assert.equals(1, #deps.store.save_calls)
    assert.equals("closed", session:state().phase)
    assert.is_false(session:state().flow:is_dirty())
  end)

  it("keeps a dirty session open and remounts when save fails", function()
    local session, deps = new_session()
    open_with_flow(session)
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
    open_with_flow(session)
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
    assert.equals(loaded.current_node_id, session:state().flow.current_node_id)
  end)

  it("sanitizes cached call targets before a loaded flow can render", function()
    local session, deps = new_session()
    local loaded = Fixtures.new_flow()
    local action = Actions.get("outgoing_calls")
    local external = call_location(
      Fixtures.location("lua/external-callsite.lua", 0, "external"),
      { kind = "absolute", path = "/dependencies/library.lua" }
    )
    local legacy = Fixtures.location("lua/legacy-callsite.lua", 1, "unverifiable")
    local project = call_location(Fixtures.location("lua/project.lua", 2, "project"))
    local commit = loaded:commit_navigation({
      origin_node_id = loaded.root.id,
      method = action.method,
      label = action.label,
      locations = { external, legacy, project },
      query_status = "complete",
    })
    local external_id = commit.node_id_by_identity[external.identity]
    local legacy_id = commit.node_id_by_identity[legacy.identity]
    assert.is_true(loaded:set_current(external_id))
    assert(deps.store:save(loaded))
    deps.store.save_calls = {}

    local entry =
      { path = "/project/.voyager/flows/main.json", name = "main", display_path = "lua/main.lua", updated_at = "now" }
    deps.store.entries = { entry }
    deps.store.load_result = loaded
    local loaded_sidebar = deps:new_sidebar()
    local render = loaded_sidebar.render
    function loaded_sidebar:render(flow, status)
      local cached = assert(flow:action_for(flow.root.id, action.method))
      assert.same(
        { project.identity },
        vim.tbl_map(function(target_id)
          return Locator.location_key(flow:location(target_id).location)
        end, flow:action_target_ids(cached))
      )
      assert.is_nil(flow:location(external_id))
      assert.is_nil(flow:location(legacy_id))
      local rows = Sidebar.project(flow, 80, status, { icons = deps.config.sidebar.icons })
      for _, row in ipairs(rows) do
        assert.not_equals(external_id, row.owner_id)
        assert.not_equals(legacy_id, row.owner_id)
      end
      return render(self, flow, status)
    end
    deps.next_sidebar = loaded_sidebar

    assert.is_true(session:load())
    deps.select_callback(entry, 1)
    assert.equals(loaded.root.id, session:state().flow.current_node_id)
    assert.is_true(session:state().flow:is_dirty())
    assert.equals(1, loaded_sidebar.render_count)
  end)

  it("keeps the active flow when a loaded root is outside the project", function()
    local session, deps = new_session()
    open_with_flow(session)
    local original = session:state().flow
    local loaded = Fixtures.new_flow()
    loaded.root.location.locator = { kind = "absolute", path = "/dependencies/main.lua" }
    local entry =
      { path = "/project/.voyager/flows/main.json", name = "main", display_path = "lua/main.lua", updated_at = "now" }
    deps.store.entries = { entry }
    deps.store.load_result = loaded
    local rejected_sidebar = deps:new_sidebar()
    deps.next_sidebar = rejected_sidebar

    assert.is_true(session:load())
    deps.select_callback(entry, 1)
    assert.equals(original, session:state().flow)
    assert.equals(0, #rejected_sidebar.mount_calls)
    assert.matches("outside project files", deps.notifications[#deps.notifications].message, nil, true)
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
    assert.matches("flow changed after listing", deps.notifications[#deps.notifications].message, nil, true)
  end)

  it("retires an active flow only after the loaded sidebar mounts", function()
    local session, deps = new_session()
    open_with_flow(session)
    session:run_action("definition")
    local original = session:state().flow
    local generation = session:state().generation
    local old_sidebar = deps.sidebar
    local old_state = session:state()
    local old_handle = deps.lsp.handles[1]
    local loaded = Fixtures.new_flow()
    local entry =
      { path = "/project/.voyager/flows/main.json", name = "main", display_path = "lua/main.lua", updated_at = "now" }
    deps.store.entries = { entry }
    deps.store.load_result = loaded
    local loaded_sidebar = deps:new_sidebar()
    deps.next_sidebar = loaded_sidebar
    deps.next_lsp = deps:new_lsp()
    loaded_sidebar.on_mount = function()
      assert.equals(original, session:state().flow)
      assert.equals(generation, session:state().generation)
      assert.equals(0, #old_handle.cancel_calls)
    end

    deps.sidebar:focus()
    local old_tracking_token = old_state.tracking_token
    assert.is_true(session:load())
    deps.select_callback(entry, 1)
    assert.equals(loaded, session:state().flow)
    assert.equals(generation + 1, session:state().generation)
    assert.equals(loaded_sidebar, session:state().sidebar)
    assert.same({ "load" }, old_handle.cancel_calls)
    assert.equals(old_tracking_token + 1, old_state.tracking_token)
    assert.is_nil(old_state.destination_claim)
    assert.is_false(old_sidebar:is_mounted())
  end)

  it("re-reads a selected flow after saving the dirty active flow", function()
    local session, deps = new_session()
    open_with_flow(session)
    assert.is_true(session:state().flow:set_note(deps.root_id, "important for auth"))
    local stale = Fixtures.new_flow()
    local updated = Fixtures.new_flow()
    assert.is_true(updated:set_note(updated.root.id, "important for auth"))
    assert(deps.store:save(updated))
    deps.store.save_calls = {}
    local entry =
      { path = "/project/.voyager/flows/main.json", name = "main", display_path = "lua/main.lua", updated_at = "now" }
    deps.store.entries = { entry }
    deps.store.load_hook = function()
      return #deps.store.save_calls == 0 and stale or updated
    end
    deps.next_sidebar = deps:new_sidebar()
    deps.next_lsp = deps:new_lsp()

    assert.is_true(session:load())
    deps.select_callback(entry, 1)
    deps.select_callback("Save", 1)

    assert.equals(1, #deps.store.save_calls)
    assert.equals(1, #deps.store.load_calls)
    assert.equals("important for auth", session:state().flow.root.note)
    assert.is_false(session:state().flow:is_dirty())
  end)

  it("rolls back the old popup when a loaded flow cannot mount", function()
    local session, deps = new_session()
    open_with_flow(session)
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
    deps.next_lsp = deps:new_lsp()
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
    open_with_flow(session)
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

  it("preserves a project-safe saved current from unlinked history", function()
    local session, deps = new_session()
    local loaded = Fixtures.new_flow()
    local result = Fixtures.location("lua/history.lua", 1)
    local commit = loaded:commit_navigation({
      origin_node_id = loaded.root.id,
      method = "textDocument/definition",
      label = "definition",
      locations = { result },
    })
    local saved_id = commit.node_id_by_identity[result.identity]
    assert.is_true(loaded:unlink_target(commit.action_id, saved_id))
    assert.is_true(loaded:set_current(saved_id))
    assert(deps.store:save(loaded))
    deps.store.save_calls = {}
    local entry =
      { path = "/project/.voyager/flows/main.json", name = "main", display_path = "lua/main.lua", updated_at = "now" }
    deps.store.entries = { entry }
    deps.store.load_result = loaded

    assert.is_true(session:load())
    deps.select_callback(entry, 1)
    assert.equals(saved_id, session:state().flow.current_node_id)
    assert.is_false(session:state().flow:is_dirty())
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
    open_with_flow(session)
    assert.is_true(session:edit_note({ kind = "location", owner_id = deps.root_id }))
    local late_note = deps.input_callback
    local entry =
      { path = "/project/.voyager/flows/main.json", name = "main", display_path = "lua/main.lua", updated_at = "now" }
    deps.store.entries = { entry }
    deps.store.load_result = Fixtures.new_flow()
    deps.next_sidebar = deps:new_sidebar()
    deps.next_lsp = deps:new_lsp()

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
    open_with_flow(session)
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
    assert.is_nil(session:state().destination_claim)
    assert.same({ deps.created_augroup.id }, deps.deleted_augroups)
    assert.same({ { owned = true } }, deps.sidebar.unmount_calls)
    assert.equals(deps.origin_win, deps.current_win_id)

    session:close("again")
    assert.equals(1, #deps.sidebar.unmount_calls)

    session, deps = new_session()
    open_with_flow(session)
    deps.sidebar:focus()
    assert.equals(deps.sidebar.winid, deps.current_win_id)
    session:close("sidebar")
    assert.equals(deps.origin_win, deps.current_win_id)
  end)

  it("shutdown never asks about a dirty flow", function()
    local session, deps = new_session()
    open_with_flow(session)
    assert.is_true(session:state().flow:set_note(deps.root_id, "dirty"))
    session:shutdown()
    assert.is_false(session:is_active())
    assert.is_nil(deps.select_callback)
  end)

  it("wires native sidebar callbacks back to one controller", function()
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
      sidebar = function(opts)
        captured.sidebar = opts
        return deps.sidebar
      end,
      lsp = function(locator, config)
        captured.lsp = { locator = locator, config = config }
        return deps.lsp
      end,
    }
    local session = Session.native(function()
      return vim.deepcopy(deps.config)
    end, deps.runtime, factories)
    open_with_flow(session)
    assert.same({
      project_root = deps.project_root,
      resolve_uri = deps.config.storage.resolve_uri,
    }, captured.locator)
    assert.equals(deps.locator, captured.lsp.locator)
    assert.same(deps.config, captured.lsp.config)

    local row = { kind = "location", owner_id = deps.root_id }
    local calls = {}
    session.activate_row = function(_, value, opts)
      if opts and opts.stay then
        calls.activate_stay = value
      else
        calls.activate = value
      end
    end
    session.delete_row = function(_, value)
      calls.delete = value
    end
    session.preview_row = function(_, value)
      calls.preview = value
    end
    session.follow_preview = function(_, value)
      calls.cursor_row = value
    end
    session.set_all_collapsed = function(_, value)
      calls.collapsed = value
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
    session.choose_jump_window = function()
      return deps.origin_win
    end

    captured.sidebar.handlers.activate(row)
    captured.sidebar.handlers.activate_stay(row)
    captured.sidebar.handlers.delete(row)
    captured.sidebar.handlers.preview(row)
    captured.sidebar.handlers.cursor_row(row)
    captured.sidebar.handlers.collapse_all()
    assert.is_true(calls.collapsed)
    captured.sidebar.handlers.expand_all()
    captured.sidebar.handlers.note(row)
    captured.sidebar.handlers.toggle(row)
    captured.sidebar.handlers.save()
    captured.sidebar.handlers.load()
    captured.sidebar.handlers.close()
    assert.equals(row, calls.activate)
    assert.equals(row, calls.activate_stay)
    assert.equals(row, calls.delete)
    assert.equals(row, calls.preview)
    assert.equals(row, calls.cursor_row)
    assert.is_false(calls.collapsed)
    assert.equals(row, calls.note)
    assert.equals(row, calls.toggle)
    for _, removed in ipairs({
      "run_action",
      "show_callers",
      "show_callees",
      "refresh_callers",
      "refresh_callees",
      "build_callers",
      "build_callees",
      "cancel_build",
    }) do
      assert.is_nil(captured.sidebar.handlers[removed])
    end
    assert.is_true(calls.save)
    assert.is_true(calls.load)
    assert.equals("sidebar", calls.close)

    captured.sidebar.handlers.external_close()
    assert.equals("external_popup", calls.close)
  end)
end)
