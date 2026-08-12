local Config = require("voyager.config")
local FakePopup = require("tests.helpers.fake_popup")
local Fixtures = require("tests.helpers.flow")
local Locator = require("voyager.locator")
local Sidebar = require("voyager.sidebar")

local function row_for(rows, kind, owner_id)
  for index, row in ipairs(rows) do
    if row.kind == kind and row.owner_id == owner_id then
      return row, index
    end
  end
end

describe("Voyager sidebar projection", function()
  local text_icons = Config.resolve({ sidebar = { icons = false } }).sidebar.icons

  it("projects the flow in stable depth-first order", function()
    local flow = Fixtures.branched_flow()
    local rows, header = Sidebar.project(flow, 42, { dirty = true, request_count = 2 }, { icons = text_icons })
    assert.same(
      {
        { kind = "location", owner_id = flow.root.id },
        { kind = "action", owner_id = flow.root.actions[1].id },
        { kind = "location", owner_id = flow.root.actions[1].results[1].id },
        { kind = "note", owner_id = flow.root.actions[1].results[1].id },
        { kind = "location", owner_id = flow.root.actions[1].results[2].id },
      },
      vim.tbl_map(function(row)
        return { kind = row.kind, owner_id = row.owner_id }
      end, rows)
    )
    assert.matches("%*", header.text)
    assert.matches("2 requests", header.text)
  end)

  it("keeps duplicate display text distinct by kind and owner ID", function()
    local flow = Fixtures.branched_flow()
    local first = flow.root.actions[1].results[1]
    local second = flow.root.actions[1].results[2]
    second.location = vim.deepcopy(first.location)
    local rows = Sidebar.project(flow, 42, { dirty = false, request_count = 0 }, { icons = text_icons })
    local first_row = assert(row_for(rows, "location", first.id))
    local second_row, second_index = row_for(rows, "location", second.id)

    assert.equals(first_row.text, second_row.text)
    assert.equals(second_index, Sidebar.selection_index(rows, "location", second.id))
  end)

  it("marks current, stale, empty, and collapsed descendant states", function()
    local flow = Fixtures.branched_flow()
    local implementation = flow.root.actions[1]
    local mysql = implementation.results[1]
    local nested = flow:commit_navigation({
      origin_node_id = mysql.id,
      method = "textDocument/references",
      label = "references",
      locations = { Fixtures.location("lua/auth.lua", 8, "AuthService.login") },
    })
    local auth_id = nested.node_id_by_identity[Fixtures.identity("lua/auth.lua", 8)]
    assert.is_true(flow:set_current(auth_id))
    local empty = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/references",
      label = "references",
      locations = {},
    })
    implementation.results[2].stale = true

    local expanded = Sidebar.project(flow, 42, { dirty = true, request_count = 0 }, { icons = text_icons })
    assert.equals("current", row_for(expanded, "location", auth_id).marker)
    assert.equals("stale", row_for(expanded, "location", implementation.results[2].id).marker)
    assert.matches("references %(0%)", row_for(expanded, "action", empty.action_id).text)

    assert.is_true(flow:toggle(implementation.id))
    local collapsed = Sidebar.project(flow, 42, { dirty = true, request_count = 0 }, { icons = text_icons })
    local action_row, action_index = row_for(collapsed, "action", implementation.id)
    assert.equals("descendant_current", action_row.marker)
    assert.is_nil(row_for(collapsed, "location", auth_id))
    assert.equals(
      action_index,
      Sidebar.selection_index(collapsed, "location", auth_id, { kind = "action", owner_id = implementation.id })
    )
  end)

  it("renders project, absolute, and URI locations with one-based lines", function()
    local flow = Fixtures.new_flow()
    local project = Fixtures.location("lua/auth.lua", 2, "project")
    local absolute = Fixtures.location("unused", 3, "absolute")
    absolute.locator = { kind = "absolute", path = "/opt/vendor/auth.lua" }
    absolute.identity = Locator.location_key(absolute)
    local uri = Fixtures.location("unused", 4, "uri")
    uri.locator = { kind = "uri", uri = "jdt://contents/Auth.class" }
    uri.identity = Locator.location_key(uri)
    local commit = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/definition",
      label = "definition",
      locations = { project, absolute, uri },
    })
    local rows = Sidebar.project(flow, 80, { dirty = true, request_count = 0 }, { icons = text_icons })

    assert.matches(
      "lua/auth.lua:3",
      row_for(rows, "location", commit.node_id_by_identity[project.identity]).text,
      nil,
      true
    )
    assert.matches(
      "/opt/vendor/auth.lua:4",
      row_for(rows, "location", commit.node_id_by_identity[absolute.identity]).text,
      nil,
      true
    )
    assert.matches(
      "jdt://contents/Auth.class:5",
      row_for(rows, "location", commit.node_id_by_identity[uri.identity]).text,
      nil,
      true
    )
  end)

  it("separates test-file results under a collapsed tests group", function()
    local flow = Fixtures.new_flow()
    local site = Fixtures.location("src/main/java/Service.java", 4, "Service.accept")
    local test_a = Fixtures.location("src/test/java/ServiceTest.java", 9, "ServiceTest.accepts")
    local test_b = Fixtures.location("tests/unit/service_spec.lua", 2, "spec")
    local commit = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/references",
      label = "usages",
      locations = { site, test_a, test_b },
    })
    local display = { icons = text_icons, test_paths = { "/src/test/", "^tests/" } }
    local site_id = commit.node_id_by_identity[site.identity]
    local test_a_id = commit.node_id_by_identity[test_a.identity]

    local rows = Sidebar.project(flow, 80, {}, display)
    assert.is_table(row_for(rows, "location", site_id))
    assert.is_nil(row_for(rows, "location", test_a_id))
    local group = row_for(rows, "group", commit.action_id)
    assert.matches("tests %(2%)", group.text)
    assert.matches("▸", group.text)

    local expanded = Sidebar.project(flow, 80, { expanded_test_groups = { [commit.action_id] = true } }, display)
    local shown = row_for(expanded, "location", test_a_id)
    assert.is_table(shown)
    assert.equals(row_for(expanded, "group", commit.action_id).depth + 1, shown.depth)

    -- current node folded inside the group surfaces the descendant marker
    assert.is_true(flow:set_current(test_a_id))
    local folded = Sidebar.project(flow, 80, {}, display)
    assert.equals("descendant_current", row_for(folded, "group", commit.action_id).marker)
  end)

  it("dims visited locations and prefixes known symbol kinds", function()
    local flow = Fixtures.new_flow()
    local site = Fixtures.location("lua/service.lua", 4, "Service.accept")
    local commit = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/references",
      label = "usages",
      locations = { site },
    })
    local site_id = commit.node_id_by_identity[site.identity]
    flow:apply_symbol(site_id, "Service.accept", "method")
    local icons = vim.deepcopy(text_icons)

    local rows = Sidebar.project(flow, 80, {}, { icons = icons })
    local site_row = row_for(rows, "location", site_id)
    assert.is_false(site_row.visited)
    assert.matches("[m] Service.accept", site_row.text, nil, true)
    local symbol_segment
    for _, segment in ipairs(site_row.segments) do
      if segment.text == "Service.accept" then
        symbol_segment = segment
      end
    end
    assert.equals("VoyagerSymbol", symbol_segment.hl)

    assert.is_true(flow:set_current(site_id))
    assert.is_true(flow:set_current(flow.root.id))
    local revisited = Sidebar.project(flow, 80, {}, { icons = icons })
    local visited_row = row_for(revisited, "location", site_id)
    assert.is_true(visited_row.visited)
    for _, segment in ipairs(visited_row.segments) do
      if segment.text == "Service.accept" then
        assert.equals("VoyagerVisited", segment.hl)
      end
    end
  end)

  it("indents one narrow column per depth by default and honors overrides", function()
    local flow = Fixtures.branched_flow()
    local mysql_id = flow.root.actions[1].results[1].id

    local narrow = Sidebar.project(flow, 80, {}, { icons = text_icons })
    assert.matches("^  ", row_for(narrow, "location", mysql_id).text)

    local wide = Sidebar.project(flow, 80, {}, { icons = text_icons, indent = 3 })
    assert.matches("^      ", row_for(wide, "location", mysql_id).text)
  end)

  it("projects a waiting placeholder when no flow exists yet", function()
    local rows, header = Sidebar.project(nil, 42, {}, { icons = text_icons })
    assert.equals("Voyager · (waiting)", header.text)
    assert.equals(1, #rows)
    assert.equals("hint", rows[1].kind)
    assert.matches("navigate to start recording", rows[1].text)
  end)

  it("indents and display-width truncates notes", function()
    local flow = Fixtures.branched_flow()
    local owner = flow.root.actions[1].results[1]
    flow:set_note(owner.id, "important 😀 authentication path that is deliberately long")
    local rows = Sidebar.project(flow, 20, { dirty = true, request_count = 0 }, { icons = text_icons })
    local note = row_for(rows, "note", owner.id)

    assert.equals(3, note.depth)
    assert.matches("^%s+✎", note.text)
    assert.is_true(vim.fn.strdisplaywidth(note.text) <= 20)
    assert.matches("…$", note.text)
  end)

  it("renders callers above their symbol and callees below", function()
    local flow = Fixtures.new_flow()
    local caller = Fixtures.location("lua/service.lua", 2, "service.persist")
    local top = Fixtures.location("lua/controller.lua", 9, "controller.create")
    local callee = Fixtures.location("lua/db.lua", 4, "db.exec")
    local refs = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/references",
      label = "references",
      locations = { caller },
    })
    local caller_id = refs.node_id_by_identity[caller.identity]
    local nested = flow:commit_navigation({
      origin_node_id = caller_id,
      method = "callHierarchy/incomingCalls",
      label = "incoming calls",
      locations = { top },
    })
    local top_id = nested.node_id_by_identity[top.identity]
    local out = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "callHierarchy/outgoingCalls",
      label = "outgoing calls",
      locations = { callee },
    })
    local callee_id = out.node_id_by_identity[callee.identity]

    local rows = Sidebar.project(flow, 80, {}, { icons = text_icons })
    assert.same(
      {
        { kind = "action", owner_id = refs.action_id },
        { kind = "action", owner_id = nested.action_id },
        { kind = "location", owner_id = top_id },
        { kind = "location", owner_id = caller_id },
        { kind = "location", owner_id = flow.root.id },
        { kind = "action", owner_id = out.action_id },
        { kind = "location", owner_id = callee_id },
      },
      vim.tbl_map(function(row)
        return { kind = row.kind, owner_id = row.owner_id }
      end, rows)
    )
  end)

  it("attaches highlight segments, direction cues, and ancestor emphasis", function()
    local flow = Fixtures.branched_flow()
    local implementations = flow.root.actions[1]
    local mysql = implementations.results[1]
    local nested = flow:commit_navigation({
      origin_node_id = mysql.id,
      method = "textDocument/references",
      label = "references",
      locations = { Fixtures.location("lua/auth.lua", 8, "AuthService.login") },
    })
    local auth_id = nested.node_id_by_identity[Fixtures.identity("lua/auth.lua", 8)]
    assert.is_true(flow:set_current(auth_id))

    local rows = Sidebar.project(flow, 80, {}, { icons = text_icons })
    local function groups(row_value)
      local result = {}
      for _, part in ipairs(row_value.segments) do
        if part.hl and part.text ~= "" then
          result[part.hl] = true
        end
      end
      return result
    end

    local impl_row = row_for(rows, "action", implementations.id)
    assert.matches("▼", impl_row.text, nil, true)
    assert.is_true(groups(impl_row)["VoyagerDirectionDown"])
    assert.is_true(groups(impl_row)["VoyagerActionLabel"])
    assert.is_true(groups(impl_row)["VoyagerCount"])

    local refs_row = row_for(rows, "action", nested.action_id)
    assert.matches("▲", refs_row.text, nil, true)
    assert.is_true(groups(refs_row)["VoyagerDirectionUp"])

    assert.is_true(groups(row_for(rows, "location", mysql.id))["VoyagerAncestor"])
    assert.is_true(groups(row_for(rows, "location", implementations.results[2].id))["VoyagerSymbol"])
    assert.is_true(groups(row_for(rows, "location", auth_id))["VoyagerCurrent"])
    assert.is_true(groups(row_for(rows, "note", mysql.id))["VoyagerNote"])

    local _, header = Sidebar.project(flow, 80, { dirty = true, request_count = 1 }, { icons = text_icons })
    local header_groups = {}
    for _, part in ipairs(header.segments) do
      header_groups[part.hl or ""] = true
    end
    assert.is_true(header_groups["VoyagerHeader"])
    assert.is_true(header_groups["VoyagerDirty"])
    assert.is_true(header_groups["VoyagerRequests"])
  end)

  it("shortens or strips paths according to the display style", function()
    local flow = Fixtures.branched_flow()
    local mysql_id = flow.root.actions[1].results[1].id

    local relative = Sidebar.project(flow, 80, {}, { icons = text_icons, path = "relative" })
    assert.matches("lua/mysql.lua:3", row_for(relative, "location", mysql_id).text, nil, true)

    local filename = Sidebar.project(flow, 80, {}, { icons = text_icons, path = "filename" })
    assert.matches("— mysql.lua:3", row_for(filename, "location", mysql_id).text, nil, true)

    local shortened = Sidebar.project(flow, 80, {}, { icons = text_icons, path = "shortened" })
    assert.matches("— l/mysql.lua:3", row_for(shortened, "location", mysql_id).text, nil, true)
  end)

  it("renders configurable action and marker icons", function()
    local flow = Fixtures.branched_flow()
    local nerd = Config.resolve().sidebar.icons
    local rows = Sidebar.project(flow, 60, {}, { icons = nerd })
    local action_row = row_for(rows, "action", flow.root.actions[1].id)
    assert.matches(nerd.implementation, action_row.text, nil, true)
    assert.matches(nerd.expanded, action_row.text, nil, true)
    assert.matches(nerd.note, row_for(rows, "note", flow.root.actions[1].results[1].id).text, nil, true)
    assert.matches(nerd.current, row_for(rows, "location", flow.root.id).text, nil, true)

    local custom = Config.resolve({ sidebar = { icons = { implementation = "I>", current = "*" } } }).sidebar.icons
    rows = Sidebar.project(flow, 60, {}, { icons = custom })
    assert.matches("I> implementations", row_for(rows, "action", flow.root.actions[1].id).text, nil, true)
    assert.matches("^%* main", row_for(rows, "location", flow.root.id).text)
  end)
end)

describe("Voyager sidebar popup", function()
  local function ui_state(overrides)
    return vim.tbl_extend("force", {
      columns = 120,
      lines = 40,
      tabline_rows = 1,
      statusline_rows = 1,
      cmdheight = 1,
    }, overrides or {})
  end

  local function noop_handlers(overrides)
    local noop = function() end
    return vim.tbl_extend("force", {
      activate = noop,
      note = noop,
      save = noop,
      load = noop,
      toggle = noop,
      close = noop,
      external_close = noop,
    }, overrides or {})
  end

  it("computes the content envelope and fits compact content to the pinned edge", function()
    local config = { side = "right", width = 42, border = "rounded" }
    local envelope = assert(Sidebar.compute_envelope(config, ui_state()))
    assert.same({ row = 1, columns = 120, side = "right", max_width = 42, max_height = 37 }, envelope)

    assert.same(
      { row = 1, col = 94, width = 26, height = 8 },
      Sidebar.fit(config, envelope, { width = 24, height = 6 })
    )
    assert.same(
      { row = 1, col = 78, width = 42, height = 37 },
      Sidebar.fit(config, envelope, { width = 90, height = 80 })
    )
    assert.same(
      { row = 1, col = 100, width = 20, height = 3 },
      Sidebar.fit(config, envelope, { width = 3, height = 1 })
    )
    assert.same({ row = 1, col = 100, width = 20, height = 3 }, Sidebar.fit(config, envelope, nil))

    local left_config = { side = "left", width = 42, border = "rounded" }
    local left = assert(
      Sidebar.compute_envelope(
        left_config,
        ui_state({ columns = 30, lines = 30, tabline_rows = 2, statusline_rows = 2, cmdheight = 2 })
      )
    )
    assert.same({ row = 2, columns = 30, side = "left", max_width = 28, max_height = 24 }, left)
    assert.same(
      { row = 2, col = 0, width = 22, height = 7 },
      Sidebar.fit(left_config, left, { width = 20, height = 5 })
    )
  end)

  it("rejects editor grids and usable heights below their minimums", function()
    local envelope, reason = Sidebar.compute_envelope(
      { side = "right", width = 20, border = "rounded" },
      ui_state({ columns = 23, lines = 12, tabline_rows = 0, statusline_rows = 1, cmdheight = 1 })
    )
    assert.is_nil(envelope)
    assert.equals("editor must be at least 24 columns wide", reason)

    envelope, reason = Sidebar.compute_envelope(
      { side = "right", width = 20, border = "rounded" },
      ui_state({ columns = 24, lines = 6, tabline_rows = 1, statusline_rows = 1, cmdheight = 1 })
    )
    assert.is_nil(envelope)
    assert.equals("editor must have at least 4 usable rows", reason)

    assert.same(
      { row = 1, columns = 24, side = "right", max_width = 20, max_height = 4 },
      Sidebar.compute_envelope(
        { side = "right", width = 20, border = "rounded" },
        ui_state({ columns = 24, lines = 7, tabline_rows = 1, statusline_rows = 1, cmdheight = 1 })
      )
    )
  end)

  it("owns one scratch popup and delegates buffer-local typed actions", function()
    local fake = FakePopup.new()
    local calls = {}
    local config = Config.resolve({ sidebar = { icons = false } })
    local sidebar = Sidebar.new({
      sidebar = config.sidebar,
      keymaps = config.sidebar_keymaps,
      handlers = noop_handlers({
        activate = function(row)
          calls.activate = row
        end,
        note = function(row)
          calls.note = row
        end,
        save = function()
          calls.save = true
        end,
        load = function()
          calls.load = true
        end,
        toggle = function(row)
          calls.toggle = row
        end,
        close = function()
          calls.close = true
        end,
      }),
      popup_factory = fake.factory,
      ui_state = ui_state,
      notify = function() end,
    })

    assert.is_true(sidebar:mount({ tabpage = 1, focus = false }))
    assert.is_true(sidebar:is_mounted())
    assert.equals(1, #fake.factory_calls)
    assert.same({ row = 1, col = 100 }, fake.factory_calls[1].position)
    assert.same({ width = 18, height = 1 }, fake.factory_calls[1].size)
    assert.equals("nofile", vim.bo[fake.bufnr].buftype)
    assert.equals(0, fake.focus_count)

    local flow = Fixtures.branched_flow()
    sidebar:render(flow, { dirty = false, request_count = 0 })
    assert.same({
      relative = "editor",
      position = { row = 1, col = 78 },
      size = { width = 40, height = 6 },
    }, fake.update_layout_calls[#fake.update_layout_calls])
    assert.equals(flow.root.id, sidebar:selected_row().owner_id)
    assert.is_true(sidebar:owns_window(fake.winid))

    fake.press("<CR>")
    fake.press("n")
    fake.press("za")
    fake.press("s")
    fake.press("L")
    fake.press("q")
    assert.equals("location", calls.activate.kind)
    assert.equals(flow.root.id, calls.note.owner_id)
    assert.equals(flow.root.id, calls.toggle.owner_id)
    assert.is_true(calls.save)
    assert.is_true(calls.load)
    assert.is_true(calls.close)

    sidebar:unmount({ owned = true })
    assert.is_false(vim.api.nvim_buf_is_valid(fake.bufnr))
  end)

  it("passes every selected row type while lifecycle keys remain row-independent", function()
    local fake = FakePopup.new()
    local calls = { activate = {}, note = {}, toggle = {}, save = 0, load = 0, close = 0 }
    local config = Config.resolve({ sidebar = { icons = false } })
    local sidebar = Sidebar.new({
      sidebar = config.sidebar,
      keymaps = config.sidebar_keymaps,
      handlers = noop_handlers({
        activate = function(row)
          table.insert(calls.activate, row)
        end,
        note = function(row)
          table.insert(calls.note, row)
        end,
        toggle = function(row)
          table.insert(calls.toggle, row)
        end,
        save = function()
          calls.save = calls.save + 1
        end,
        load = function()
          calls.load = calls.load + 1
        end,
        close = function()
          calls.close = calls.close + 1
        end,
      }),
      popup_factory = fake.factory,
      ui_state = ui_state,
      notify = function() end,
    })
    assert.is_true(sidebar:mount({ tabpage = 1, focus = false }))
    local flow = Fixtures.branched_flow()
    sidebar:render(flow, { dirty = true, request_count = 0 })
    local rows = Sidebar.project(flow, 40, {}, { icons = config.sidebar.icons })
    local targets = {
      assert(row_for(rows, "location", flow.root.id)),
      assert(row_for(rows, "action", flow.root.actions[1].id)),
      (assert(row_for(rows, "note", flow.root.actions[1].results[1].id))),
    }

    for _, target in ipairs(targets) do
      local _, index = row_for(rows, target.kind, target.owner_id)
      fake.set_cursor_line(index + 1)
      fake.press("<CR>")
      fake.press("n")
      fake.press("za")
      fake.press("s")
      fake.press("L")
      fake.press("q")
    end

    for _, name in ipairs({ "activate", "note", "toggle" }) do
      assert.same(
        { "location", "action", "note" },
        vim.tbl_map(function(row)
          return row.kind
        end, calls[name])
      )
    end
    assert.equals(3, calls.save)
    assert.equals(3, calls.load)
    assert.equals(3, calls.close)
    sidebar:unmount({ owned = true })
  end)

  it("preserves selection and focus across renders and collapsed fallback", function()
    local fake = FakePopup.new()
    local sidebar_config = Config.resolve({ sidebar = { icons = false } }).sidebar
    local sidebar = Sidebar.new({
      sidebar = sidebar_config,
      keymaps = {},
      handlers = noop_handlers(),
      popup_factory = fake.factory,
      ui_state = ui_state,
      notify = function() end,
    })
    assert.is_true(sidebar:mount({ tabpage = 1, focus = false }))

    local flow = Fixtures.branched_flow()
    local action = flow.root.actions[1]
    local selected = action.results[2]
    sidebar:render(flow, { dirty = false, request_count = 0 })
    local rows = Sidebar.project(flow, 40, {}, { icons = sidebar_config.icons })
    local _, selected_index = row_for(rows, "location", selected.id)
    fake.set_cursor_line(selected_index + 1)
    local source_win = vim.api.nvim_get_current_win()

    sidebar:render(flow, { dirty = true, request_count = 1 })
    assert.equals(selected.id, sidebar:selected_row().owner_id)
    assert.equals(source_win, vim.api.nvim_get_current_win())
    assert.equals(0, fake.focus_count)

    assert.is_true(flow:toggle(action.id))
    sidebar:render(flow, { dirty = true, request_count = 0 })
    assert.equals("action", sidebar:selected_row().kind)
    assert.equals(action.id, sidebar:selected_row().owner_id)
    assert.equals(source_win, vim.api.nvim_get_current_win())

    sidebar:unmount({ owned = true })
  end)

  it("hides on invalid remount and distinguishes owned from external closes", function()
    local fake = FakePopup.new()
    local state = ui_state()
    local external_closes = 0
    local sidebar = Sidebar.new({
      sidebar = Config.resolve({ sidebar = { width = 20, icons = false } }).sidebar,
      keymaps = {},
      handlers = noop_handlers({
        external_close = function()
          external_closes = external_closes + 1
        end,
      }),
      popup_factory = fake.factory,
      ui_state = function()
        return vim.deepcopy(state)
      end,
      notify = function() end,
    })
    assert.is_true(sidebar:mount({ tabpage = 1, focus = false }))

    state.columns = 23
    local mounted, reason = sidebar:remount({ tabpage = 1, focus = false })
    assert.is_nil(mounted)
    assert.equals("editor must be at least 24 columns wide", reason)
    assert.is_false(sidebar:is_mounted())
    assert.equals(0, external_closes)

    state.columns = 80
    assert.is_true(sidebar:remount({ tabpage = 1, focus = false }))
    assert.is_true(sidebar:is_mounted())
    assert.equals(0, fake.focus_count)
    assert.equals(0, external_closes)

    fake.external_close()
    assert.is_false(sidebar:is_mounted())
    assert.equals(1, external_closes)

    assert.is_true(sidebar:remount({ tabpage = 1, focus = false }))
    sidebar:unmount({ owned = true })
    assert.equals(1, external_closes)
  end)

  it("refits the popup as rendered content grows and collapses", function()
    local fake = FakePopup.new()
    local sidebar = Sidebar.new({
      sidebar = Config.resolve({ sidebar = { icons = false } }).sidebar,
      keymaps = {},
      handlers = noop_handlers(),
      popup_factory = fake.factory,
      ui_state = ui_state,
      notify = function() end,
    })
    assert.is_true(sidebar:mount({ tabpage = 1, focus = false }))

    local flow = Fixtures.branched_flow()
    sidebar:render(flow, { dirty = false, request_count = 0 })
    local grown = fake.update_layout_calls[#fake.update_layout_calls]
    assert.same({ width = 40, height = 6 }, grown.size)

    assert.is_true(flow:toggle(flow.root.actions[1].id))
    sidebar:render(flow, { dirty = true, request_count = 0 })
    local collapsed = fake.update_layout_calls[#fake.update_layout_calls]
    assert.same({ width = 25, height = 3 }, collapsed.size)
    assert.same({ row = 1, col = 93 }, collapsed.position)

    sidebar:render(flow, { dirty = true, request_count = 0 })
    assert.same(collapsed, fake.update_layout_calls[#fake.update_layout_calls])
    sidebar:unmount({ owned = true })
  end)

  it("applies highlight extmarks to the rendered popup buffer", function()
    local fake = FakePopup.new()
    local sidebar = Sidebar.new({
      sidebar = Config.resolve({ sidebar = { icons = false } }).sidebar,
      keymaps = {},
      handlers = noop_handlers(),
      popup_factory = fake.factory,
      ui_state = ui_state,
      notify = function() end,
    })
    assert.is_true(sidebar:mount({ tabpage = 1, focus = false }))
    sidebar:render(Fixtures.branched_flow(), { dirty = true, request_count = 0 })

    local namespace = vim.api.nvim_create_namespace("voyager-sidebar")
    local marks = vim.api.nvim_buf_get_extmarks(fake.bufnr, namespace, 0, -1, { details = true })
    local seen = {}
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.hl_group then
        seen[details.hl_group] = true
      end
      if details.line_hl_group then
        seen[details.line_hl_group] = true
      end
    end
    assert.is_true(seen["VoyagerHeader"])
    assert.is_true(seen["VoyagerDirty"])
    assert.is_true(seen["VoyagerSymbol"])
    assert.is_true(seen["VoyagerPath"])
    assert.is_true(seen["VoyagerActionLabel"])
    assert.is_true(seen["VoyagerCount"])
    assert.is_true(seen["VoyagerNote"])
    assert.is_true(seen["VoyagerCurrentLine"])
    sidebar:unmount({ owned = true })
  end)

  it("keeps the follow preview open across cursor moves and closes it on focus loss", function()
    local fake = FakePopup.new()
    local config = Config.resolve({ sidebar = { icons = false } })
    local cursor_rows = {}
    local sidebar = Sidebar.new({
      sidebar = config.sidebar,
      keymaps = config.sidebar_keymaps,
      handlers = noop_handlers({
        cursor_row = function(row)
          table.insert(cursor_rows, row or false)
        end,
      }),
      popup_factory = fake.factory,
      ui_state = ui_state,
      notify = function() end,
    })
    assert.is_true(sidebar:mount({ tabpage = 1, focus = false }))
    sidebar:render(Fixtures.branched_flow(), { dirty = false, request_count = 0 })
    local windows_before = #vim.api.nvim_list_wins()

    assert.is_true(sidebar:show_preview({
      lines = { "local function save()", "end" },
      title = " save ",
      focus_line = 1,
      filetype = "lua",
      key = "loc-save",
    }))
    assert.equals(windows_before + 1, #vim.api.nvim_list_wins())

    -- moving the cursor keeps the float and re-dispatches the row handler
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = fake.bufnr })
    assert.equals(windows_before + 1, #vim.api.nvim_list_wins())
    assert.is_true(#cursor_rows > 0)

    -- an unchanged key is a no-op render
    local preview_win = sidebar._preview.winid
    assert.is_true(sidebar:show_preview({ lines = { "other" }, key = "loc-save" }))
    assert.equals(preview_win, sidebar._preview.winid)

    vim.api.nvim_exec_autocmds("BufLeave", { buffer = fake.bufnr })
    assert.equals(windows_before, #vim.api.nvim_list_wins())

    assert.is_true(sidebar:show_help())
    assert.equals(windows_before + 1, #vim.api.nvim_list_wins())
    sidebar:unmount({ owned = true })
    assert.equals(windows_before, #vim.api.nvim_list_wins())
  end)

  it("closes a peek preview on cursor move when follow mode is disabled", function()
    local fake = FakePopup.new()
    local config = Config.resolve({ sidebar = { icons = false, preview = false } })
    local sidebar = Sidebar.new({
      sidebar = config.sidebar,
      keymaps = config.sidebar_keymaps,
      handlers = noop_handlers(),
      popup_factory = fake.factory,
      ui_state = ui_state,
      notify = function() end,
    })
    assert.is_true(sidebar:mount({ tabpage = 1, focus = false }))
    sidebar:render(Fixtures.branched_flow(), { dirty = false, request_count = 0 })
    local windows_before = #vim.api.nvim_list_wins()

    assert.is_true(sidebar:show_preview({ lines = { "peek" }, title = " peek " }))
    assert.equals(windows_before + 1, #vim.api.nvim_list_wins())
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = fake.bufnr })
    assert.equals(windows_before, #vim.api.nvim_list_wins())
    sidebar:unmount({ owned = true })
  end)

  it("mounts only a scratch popup and preserves the source window", function()
    local source = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(source, vim.fn.tempname() .. ".lua")
    vim.api.nvim_set_current_buf(source)
    vim.bo[source].modifiable = true
    vim.bo[source].readonly = false
    local source_win = vim.api.nvim_get_current_win()
    local windows_before = #vim.api.nvim_list_wins()
    local noop = function() end

    local sidebar = Sidebar.new({
      sidebar = Config.resolve({ sidebar = { width = 20, icons = false } }).sidebar,
      keymaps = {
        jump_or_toggle = false,
        note = false,
        save = false,
        load = false,
        toggle = false,
        close = false,
      },
      handlers = {
        activate = noop,
        note = noop,
        save = noop,
        load = noop,
        toggle = noop,
        close = noop,
        external_close = noop,
      },
      notify = noop,
    })

    assert.is_true(sidebar:mount({ tabpage = vim.api.nvim_get_current_tabpage(), focus = false }))
    assert.equals(source_win, vim.api.nvim_get_current_win())
    assert.equals(source, vim.api.nvim_win_get_buf(source_win))
    assert.is_true(vim.bo[source].modifiable)
    assert.is_false(vim.bo[source].readonly)
    assert.equals(windows_before + 1, #vim.api.nvim_list_wins())

    local popup_win
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
      if sidebar:owns_window(winid) then
        popup_win = winid
      end
    end
    assert.is_not_nil(popup_win)
    assert.equals("nofile", vim.bo[vim.api.nvim_win_get_buf(popup_win)].buftype)

    sidebar:unmount({ owned = true })
    assert.equals(windows_before, #vim.api.nvim_list_wins())
    vim.api.nvim_buf_delete(source, { force = true })
  end)
end)
