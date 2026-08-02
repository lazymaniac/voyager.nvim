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
  it("projects the flow in stable depth-first order", function()
    local flow = Fixtures.branched_flow()
    local rows, header = Sidebar.project(flow, 42, { dirty = true, request_count = 2 })
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
    assert.matches("%*", header)
    assert.matches("2 requests", header)
  end)

  it("keeps duplicate display text distinct by kind and owner ID", function()
    local flow = Fixtures.branched_flow()
    local first = flow.root.actions[1].results[1]
    local second = flow.root.actions[1].results[2]
    second.location = vim.deepcopy(first.location)
    local rows = Sidebar.project(flow, 42, { dirty = false, request_count = 0 })
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

    local expanded = Sidebar.project(flow, 42, { dirty = true, request_count = 0 })
    assert.equals("current", row_for(expanded, "location", auth_id).marker)
    assert.equals("stale", row_for(expanded, "location", implementation.results[2].id).marker)
    assert.matches("references %(0%)", row_for(expanded, "action", empty.action_id).text)

    assert.is_true(flow:toggle(implementation.id))
    local collapsed = Sidebar.project(flow, 42, { dirty = true, request_count = 0 })
    local action_row, action_index = row_for(collapsed, "action", implementation.id)
    assert.equals("descendant_current", action_row.marker)
    assert.is_nil(row_for(collapsed, "location", auth_id))
    assert.equals(action_index, Sidebar.selection_index(collapsed, "location", auth_id, implementation.id))
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
    local rows = Sidebar.project(flow, 80, { dirty = true, request_count = 0 })

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

  it("indents and display-width truncates notes", function()
    local flow = Fixtures.branched_flow()
    local owner = flow.root.actions[1].results[1]
    flow:set_note(owner.id, "important 😀 authentication path that is deliberately long")
    local rows = Sidebar.project(flow, 20, { dirty = true, request_count = 0 })
    local note = row_for(rows, "note", owner.id)

    assert.equals(3, note.depth)
    assert.matches("^%s+✎", note.text)
    assert.is_true(vim.fn.strdisplaywidth(note.text) <= 20)
    assert.matches("…$", note.text)
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

  it("computes outer geometry for both sides and editor chrome", function()
    assert.same(
      { row = 1, col = 78, width = 42, height = 37 },
      Sidebar.compute_geometry({ side = "right", width = 42, border = "rounded" }, ui_state())
    )
    assert.same(
      { row = 2, col = 0, width = 28, height = 24 },
      Sidebar.compute_geometry(
        { side = "left", width = 42, border = "rounded" },
        ui_state({ columns = 30, lines = 30, tabline_rows = 2, statusline_rows = 2, cmdheight = 2 })
      )
    )

    for width = 20, 23 do
      local geometry = assert(
        Sidebar.compute_geometry(
          { side = "right", width = width, border = "rounded" },
          ui_state({ columns = 30, lines = 12, tabline_rows = 0, statusline_rows = 1, cmdheight = 1 })
        )
      )
      assert.equals(width, geometry.width)
      assert.equals(30 - width, geometry.col)
    end
  end)

  it("rejects editor grids and usable heights below their minimums", function()
    local geometry, reason = Sidebar.compute_geometry(
      { side = "right", width = 20, border = "rounded" },
      ui_state({ columns = 23, lines = 12, tabline_rows = 0, statusline_rows = 1, cmdheight = 1 })
    )
    assert.is_nil(geometry)
    assert.equals("editor must be at least 24 columns wide", reason)

    geometry, reason = Sidebar.compute_geometry(
      { side = "right", width = 20, border = "rounded" },
      ui_state({ columns = 24, lines = 6, tabline_rows = 1, statusline_rows = 1, cmdheight = 1 })
    )
    assert.is_nil(geometry)
    assert.equals("editor must have at least 4 usable rows", reason)

    assert.same(
      { row = 1, col = 4, width = 20, height = 4 },
      Sidebar.compute_geometry(
        { side = "right", width = 20, border = "rounded" },
        ui_state({ columns = 24, lines = 7, tabline_rows = 1, statusline_rows = 1, cmdheight = 1 })
      )
    )
  end)

  it("owns one scratch popup and delegates buffer-local typed actions", function()
    local fake = FakePopup.new()
    local calls = {}
    local config = Config.resolve()
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
    assert.same({ row = 1, col = 78 }, fake.factory_calls[1].position)
    assert.same({ width = 40, height = 35 }, fake.factory_calls[1].size)
    assert.equals("nofile", vim.bo[fake.bufnr].buftype)
    assert.equals(0, fake.focus_count)

    local flow = Fixtures.branched_flow()
    sidebar:render(flow, { dirty = false, request_count = 0 })
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
    local config = Config.resolve()
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
    local rows = Sidebar.project(flow, 40, {})
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
    local sidebar = Sidebar.new({
      sidebar = { side = "right", width = 42, border = "rounded" },
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
    local rows = Sidebar.project(flow, 40, {})
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
      sidebar = { side = "right", width = 20, border = "rounded" },
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
      sidebar = { side = "right", width = 20, border = "rounded" },
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
