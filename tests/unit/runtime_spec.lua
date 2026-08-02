local Runtime = require("voyager.runtime")

describe("Voyager runtime", function()
  local created_buffers
  local temporary_directories

  before_each(function()
    created_buffers = {}
    temporary_directories = {}
  end)

  after_each(function()
    for _, bufnr in ipairs(created_buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
    for _, directory in ipairs(temporary_directories) do
      for name in vim.fs.dir(directory) do
        pcall(vim.uv.fs_unlink, directory .. "/" .. name)
      end
      pcall(vim.uv.fs_rmdir, directory)
    end
  end)

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
    table.insert(created_buffers, bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local function main()" })
    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_win_set_cursor(winid, { 1, 15 })

    local word, start_col, end_col = runtime.word_at_cursor(bufnr, winid)
    assert.equals("main", word)
    assert.equals(15, start_col)
    assert.equals(19, end_col)
  end)

  it("finds a git root without expanding literal environment syntax", function()
    local project = vim.fn.tempname() .. "-$HOME"
    local marker = project .. "/.git"
    assert.equals(1, vim.fn.mkdir(marker, "p"))
    table.insert(temporary_directories, marker)
    table.insert(temporary_directories, project)

    assert.equals(project, Runtime.native().find_root(project .. "/lua/main.lua", ".git"))
  end)

  it("finds a loaded modified file buffer through its canonical real path", function()
    local runtime = Runtime.native()
    local directory = vim.fn.tempname()
    assert.equals(1, vim.fn.mkdir(directory, "p"))
    table.insert(temporary_directories, directory)
    local target = directory .. "/target.txt"
    local alias = directory .. "/alias.txt"
    assert.equals(0, vim.fn.writefile({ "return 'disk'" }, target))
    assert(vim.uv.fs_symlink(target, alias))
    local bufnr = vim.fn.bufadd(alias)
    table.insert(created_buffers, bufnr)
    assert.equals(0, vim.fn.bufload(bufnr))
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "return 'modified'" })

    local buffer_name = vim.api.nvim_buf_get_name(bufnr)
    local real_target = assert(vim.uv.fs_realpath(target))
    assert.matches("/alias.txt$", buffer_name)
    assert.not_equals(real_target, buffer_name)
    assert.equals(bufnr, runtime.find_buffer(real_target))

    local uri_buf = vim.api.nvim_create_buf(true, false)
    table.insert(created_buffers, uri_buf)
    vim.api.nvim_buf_set_name(uri_buf, "zip://archive/member.lua")
    assert.equals(uri_buf, runtime.find_buffer("zip://archive/member.lua"))
  end)

  it("prefers an exact buffer name over an earlier realpath-equivalent alias", function()
    local directory = vim.fn.tempname()
    assert.equals(1, vim.fn.mkdir(directory, "p"))
    table.insert(temporary_directories, directory)
    local target = directory .. "/target.txt"
    local alias = directory .. "/alias.txt"
    assert.equals(0, vim.fn.writefile({ "return true" }, target))
    assert(vim.uv.fs_symlink(target, alias))

    local originals = {
      list = vim.api.nvim_list_bufs,
      valid = vim.api.nvim_buf_is_valid,
      loaded = vim.api.nvim_buf_is_loaded,
      name = vim.api.nvim_buf_get_name,
    }
    vim.api.nvim_list_bufs = function()
      return { 91, 92 }
    end
    vim.api.nvim_buf_is_valid = function()
      return true
    end
    vim.api.nvim_buf_is_loaded = function()
      return true
    end
    vim.api.nvim_buf_get_name = function(bufnr)
      return bufnr == 91 and alias or target
    end
    local ok, found = pcall(Runtime.native().find_buffer, target)
    vim.api.nvim_list_bufs = originals.list
    vim.api.nvim_buf_is_valid = originals.valid
    vim.api.nvim_buf_is_loaded = originals.loaded
    vim.api.nvim_buf_get_name = originals.name

    assert(ok, found)
    assert.equals(92, found)
  end)
end)
