local E2E = assert(_G.VoyagerE2E)
local Schema = require("voyager.schema")
local Voyager = require("voyager")

local function row(kind, owner_id)
  return { kind = kind, owner_id = owner_id }
end

describe("Voyager restart journey: save phase", function()
  it("records, annotates, and saves the complete branch", function()
    local input_calls = 0
    local notifications = {}
    vim.notify = function(message)
      table.insert(notifications, tostring(message))
    end
    vim.ui.input = function(opts, callback)
      input_calls = input_calls + 1
      assert.is_nil(opts.default)
      callback("important for auth")
    end

    Voyager.open()
    local session = assert(Voyager._session_for_tests())
    assert.is_true(session:is_active())
    local opened = session:state()
    assert.is_true(opened.sidebar:is_mounted())
    assert.equals(E2E.source_win, vim.api.nvim_get_current_win())
    assert.equals(E2E.source_buf, vim.api.nvim_win_get_buf(E2E.source_win))
    assert.same({ 5, 15 }, vim.api.nvim_win_get_cursor(E2E.source_win))

    local popup_win
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
      if opened.sidebar:owns_window(winid) then
        popup_win = winid
      end
    end
    assert.is_not_nil(popup_win)
    assert.equals("nofile", vim.bo[vim.api.nvim_win_get_buf(popup_win)].buftype)

    vim.api.nvim_feedkeys(vim.keycode("gri"), "x", false)
    E2E.wait_for_requests(session)
    local flow = session:state().flow
    local implementations = assert(
      E2E.action(flow.root, "textDocument/implementation"),
      vim.inspect({
        notifications = notifications,
        actions = flow.root.actions,
        current = flow.current_node_id,
        root = flow.root.location,
        cursor = vim.api.nvim_win_get_cursor(E2E.source_win),
      })
    )
    assert.equals(2, #implementations.results)
    E2E.wait("the native implementation quickfix list", function()
      return #vim.fn.getqflist() == 4
    end)
    local mysql = assert(E2E.result(implementations, "lua/mysql_store.lua"))
    local memory = assert(E2E.result(implementations, "lua/memory_store.lua"))

    assert.is_table(session:state().destination_claim)
    vim.cmd("cc 1")
    vim.api.nvim_exec_autocmds("CursorMoved", { modeline = false })
    local landed_suffix = assert(vim.api.nvim_buf_get_name(0):match("lua/[^/]+%.lua$"))
    local landed = assert(E2E.result(implementations, landed_suffix))
    assert.equals(landed.id, session:state().flow.current_node_id)
    assert.is_table(session:state().destination_claim)

    local activated = session:activate_row(row("location", mysql.id))
    assert(
      activated,
      vim.inspect({
        notifications = notifications,
        current_win = vim.api.nvim_get_current_win(),
        current_buf = vim.api.nvim_get_current_buf(),
        current_name = vim.api.nvim_buf_get_name(0),
        source_win = E2E.source_win,
        source_valid = vim.api.nvim_win_is_valid(E2E.source_win),
        source_buf = vim.api.nvim_win_is_valid(E2E.source_win) and vim.api.nvim_win_get_buf(E2E.source_win) or nil,
        source_name = vim.api.nvim_win_is_valid(E2E.source_win) and vim.api.nvim_buf_get_name(
          vim.api.nvim_win_get_buf(E2E.source_win)
        ) or nil,
        source_windows = session:state().source_windows,
        target = mysql.location,
      })
    )
    assert.matches("mysql_store.lua$", vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
    assert.matches("local function save", vim.api.nvim_get_current_line())
    assert.is_nil(session:state().destination_claim)
    E2E.wait_for_clients(vim.api.nvim_get_current_buf())
    vim.api.nvim_feedkeys(vim.keycode("grr"), "x", false)
    E2E.wait_for_requests(session)
    flow = session:state().flow
    implementations = assert(E2E.action(flow.root, "textDocument/implementation"))
    mysql = assert(E2E.result(implementations, "lua/mysql_store.lua"))
    local references = assert(E2E.action(mysql, "textDocument/references"))
    assert.equals(1, #references.results)
    E2E.wait("the native references quickfix list", function()
      return #vim.fn.getqflist() == 2
    end)

    session:activate_row(row("location", flow.root.id))
    flow = session:state().flow
    implementations = assert(E2E.action(flow.root, "textDocument/implementation"))
    memory = assert(E2E.result(implementations, "lua/memory_store.lua"))
    session:activate_row(row("location", memory.id))
    session:edit_note(row("location", memory.id))
    assert.equals(1, input_calls)
    session:toggle_row(row("action", implementations.id))

    flow = session:state().flow
    implementations = assert(E2E.action(flow.root, "textDocument/implementation"))
    memory = assert(E2E.result(implementations, "lua/memory_store.lua"))
    assert.equals(memory.id, flow.current_node_id)
    assert.equals("important for auth", memory.note)
    assert.is_true(implementations.collapsed)
    assert(session:save(), vim.inspect({ notifications = notifications }))
    assert.is_false(session:state().flow:is_dirty())

    local paths = vim.fn.glob(E2E.root .. "/.voyager/flows/*.json", false, true)
    assert.equals(1, #paths)
    local encoded = table.concat(vim.fn.readfile(paths[1]), "\n") .. "\n"
    local saved = Schema.decode(encoded)
    assert.equals(memory.id, saved.current_node_id)

    local retained_buf = vim.api.nvim_get_current_buf()
    local retained_cursor = vim.api.nvim_win_get_cursor(0)
    local retained_list = vim.fn.getqflist({ id = 0, items = 0 })
    local augroup = session:state().autocmd_group
    Voyager.close()

    local closed = assert(Voyager._session_for_tests()):state()
    assert.equals("closed", closed.phase)
    assert.equals(0, closed.request_count)
    assert.equals(0, vim.tbl_count(closed.request_handles))
    assert.is_false(vim.api.nvim_win_is_valid(popup_win))
    assert.equals(retained_buf, vim.api.nvim_get_current_buf())
    assert.same(retained_cursor, vim.api.nvim_win_get_cursor(0))
    assert.equals(retained_list.id, vim.fn.getqflist({ id = 0 }).id)
    assert.equals(#retained_list.items, #vim.fn.getqflist())
    local autocmd_ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = augroup })
    assert.is_true(not autocmd_ok or #autocmds == 0)
    assert.is_false(closed.keymaps:is_installed(retained_buf, "gri"))
  end)
end)
