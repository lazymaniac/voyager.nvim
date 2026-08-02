local Runtime = require("voyager.runtime")

describe("Voyager runtime", function()
  it("returns fresh complete native adapter tables", function()
    local first = Runtime.native()
    local second = Runtime.native()
    assert.not_equals(first, second)
    for _, name in ipairs({
      "now",
      "random",
      "sha256",
      "pid",
      "cwd",
      "dirname",
      "find_root",
      "fs_realpath",
      "fs_stat",
      "fs_scandir",
      "fs_scandir_next",
      "fs_open",
      "fs_read",
      "fs_write",
      "fs_fsync",
      "fs_close",
      "fs_rename",
      "fs_unlink",
      "mkdir",
      "read_file",
      "find_buffer",
      "buffer_valid",
      "buffer_loaded",
      "buffer_name",
      "get_buffer_lines",
      "add_buffer",
      "load_buffer",
      "set_buffer_listed",
      "current_buf",
      "current_win",
      "current_tabpage",
      "open_folds",
      "get_clients",
      "make_position_params",
      "timer",
    }) do
      assert.equals("function", type(first[name]), name)
    end
  end)

  it("returns the native cursor word with both byte-column bounds", function()
    local runtime = Runtime.native()
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local function main()" })
    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_win_set_cursor(winid, { 1, 15 })

    local word, start_col, end_col = runtime.word_at_cursor(bufnr, winid)
    assert.equals("main", word)
    assert.equals(15, start_col)
    assert.equals(19, end_col)
  end)
end)
