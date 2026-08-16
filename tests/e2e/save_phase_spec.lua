local E2E = assert(_G.VoyagerE2E)
local Schema = require("voyager.schema")
local Voyager = require("voyager")

local function row(kind, owner_id)
  return { kind = kind, owner_id = owner_id }
end

describe("Voyager restart journey: save phase", function()
  it("creates, annotates, and saves the complete automatic call tree", function()
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

    E2E.wait_for_graph(session)
    local flow = session:state().flow
    assert.equals(flow.root.id, flow.current_node_id)
    local callers = assert(E2E.action(flow.root, "callHierarchy/incomingCalls"))
    assert.equals(0, #callers.results)
    local calls = assert(
      E2E.action(flow.root, "callHierarchy/outgoingCalls"),
      vim.inspect({
        notifications = notifications,
        actions = flow.root.actions,
        current = flow.current_node_id,
        root = flow.root.location,
        cursor = vim.api.nvim_win_get_cursor(E2E.source_win),
      })
    )
    assert.equals(3, #calls.results)
    local mysql = assert(E2E.result(calls, "lua/mysql_store.lua"))
    local memory = assert(E2E.result(calls, "lua/memory_store.lua"))
    local authorize = assert(E2E.result(calls, "lua/auth.lua"))
    local authorized_calls = assert(E2E.action(authorize, "callHierarchy/outgoingCalls"))
    assert.equals(2, #authorized_calls.results)
    assert.is_not_nil(E2E.result(authorized_calls, "lua/mysql_store.lua"))
    assert.is_not_nil(E2E.result(authorized_calls, "lua/memory_store.lua"))
    assert.equals(0, #assert(E2E.action(mysql, "callHierarchy/outgoingCalls")).results)
    assert.equals(0, #assert(E2E.action(memory, "callHierarchy/outgoingCalls")).results)

    local activated = session:activate_row(row("location", memory.id))
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
        target = memory.location,
      })
    )
    assert.matches("main.lua$", vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()))
    assert.matches("memory_store%.save", vim.api.nvim_get_current_line())
    assert.is_nil(session:state().destination_claim)
    assert.equals(memory.id, session:state().flow.current_node_id)
    session:edit_note(row("location", memory.id))
    assert.equals(1, input_calls)

    flow = session:state().flow
    calls = assert(E2E.action(flow.root, "callHierarchy/outgoingCalls"))
    memory = assert(E2E.result(calls, "lua/memory_store.lua"))
    assert.equals(memory.id, flow.current_node_id)
    assert.equals("important for auth", memory.note)
    assert(session:save(), vim.inspect({ notifications = notifications }))
    assert.is_false(session:state().flow:is_dirty())

    local paths = vim.fn.glob(E2E.root .. "/.voyager/flows/*.json", false, true)
    assert.equals(1, #paths)
    local encoded = table.concat(vim.fn.readfile(paths[1]), "\n") .. "\n"
    local saved = Schema.decode(encoded)
    assert.equals(memory.id, saved.current_node_id)
    local saved_calls = assert(E2E.action(saved.root, "callHierarchy/outgoingCalls"))
    assert.equals(3, #saved_calls.results)
    assert.equals("important for auth", assert(E2E.result(saved_calls, "lua/memory_store.lua")).note)

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
    local gri = vim.api.nvim_buf_call(retained_buf, function()
      return vim.fn.maparg("gri", "n", false, true)
    end)
    assert.equals(0, gri.buffer)
  end)
end)
