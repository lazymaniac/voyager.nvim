local E2E = assert(_G.VoyagerE2E)
local Voyager = require("voyager")

describe("Voyager restart journey: load phase", function()
  it("loads the independently persisted branch and tears down cleanly", function()
    local select_calls = 0
    vim.ui.select = function(items, opts, callback)
      select_calls = select_calls + 1
      assert.is_true(#items > 0)
      assert.is_function(opts.format_item)
      callback(items[1], 1)
    end

    Voyager.load()
    E2E.wait("saved flow activation", function()
      local session = Voyager._session_for_tests()
      return session ~= nil and session:is_active()
    end)

    local session = assert(Voyager._session_for_tests())
    assert.equals(1, select_calls)
    local state = session:state()
    local flow = state.flow
    local implementations = assert(E2E.action(flow.root, "textDocument/implementation"))
    assert.equals(2, #implementations.results)
    assert.is_true(implementations.collapsed)
    local mysql = assert(E2E.result(implementations, "lua/mysql_store.lua"))
    local memory = assert(E2E.result(implementations, "lua/memory_store.lua"))
    local references = assert(E2E.action(mysql, "textDocument/references"))
    assert.equals(1, #references.results)
    assert.equals("important for auth", memory.note)
    assert.equals(memory.id, flow.current_node_id)
    assert.is_false(flow:is_dirty())
    assert.is_true(state.sidebar:is_mounted())

    local popup_win
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
      if state.sidebar:owns_window(winid) then
        popup_win = winid
      end
    end
    assert.is_not_nil(popup_win)
    local augroup = state.autocmd_group
    Voyager.close()

    local closed = assert(Voyager._session_for_tests()):state()
    assert.equals("closed", closed.phase)
    assert.equals(0, closed.request_count)
    assert.equals(0, vim.tbl_count(closed.request_handles))
    assert.is_false(vim.api.nvim_win_is_valid(popup_win))
    local autocmd_ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = augroup })
    assert.is_true(not autocmd_ok or #autocmds == 0)
  end)
end)
