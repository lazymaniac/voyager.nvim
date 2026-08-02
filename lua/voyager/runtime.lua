local M = {}

function M.native()
  return {
    now = function()
      return os.date("!%Y-%m-%dT%H:%M:%SZ")
    end,
    random = vim.uv.random,
    sha256 = vim.fn.sha256,
    pid = vim.uv.os_getpid,
    cwd = vim.fn.getcwd,
    dirname = vim.fs.dirname,
    find_root = function(path, marker)
      return vim.fs.root(path, marker)
    end,

    fs_realpath = vim.uv.fs_realpath,
    fs_stat = vim.uv.fs_stat,
    fs_scandir = vim.uv.fs_scandir,
    fs_scandir_next = vim.uv.fs_scandir_next,
    fs_open = vim.uv.fs_open,
    fs_read = vim.uv.fs_read,
    fs_write = vim.uv.fs_write,
    fs_fsync = vim.uv.fs_fsync,
    fs_close = vim.uv.fs_close,
    fs_rename = vim.uv.fs_rename,
    fs_unlink = vim.uv.fs_unlink,
    mkdir = function(path)
      return vim.fn.mkdir(path, "p")
    end,
    read_file = function(path)
      local ok, lines = pcall(vim.fn.readfile, path)
      if not ok then
        return nil, tostring(lines)
      end
      return lines
    end,

    list_buffers = vim.api.nvim_list_bufs,
    find_buffer = function(exact_name)
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr)
          and vim.api.nvim_buf_is_loaded(bufnr)
          and vim.api.nvim_buf_get_name(bufnr) == exact_name
        then
          return bufnr
        end
      end
    end,
    buffer_valid = vim.api.nvim_buf_is_valid,
    buffer_loaded = vim.api.nvim_buf_is_loaded,
    buffer_name = vim.api.nvim_buf_get_name,
    get_buffer_lines = function(bufnr)
      return vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
    end,
    add_buffer = vim.fn.bufadd,
    load_buffer = function(bufnr)
      local ok, result = pcall(vim.fn.bufload, bufnr)
      if not ok then
        return false, tostring(result)
      end
      return true
    end,
    set_buffer_listed = function(bufnr, listed)
      vim.api.nvim_set_option_value("buflisted", listed, { buf = bufnr })
    end,
    buffer_option = function(bufnr, name)
      return vim.api.nvim_get_option_value(name, { buf = bufnr })
    end,
    set_buffer_option = function(bufnr, name, value)
      vim.api.nvim_set_option_value(name, value, { buf = bufnr })
    end,

    current_buf = vim.api.nvim_get_current_buf,
    current_win = vim.api.nvim_get_current_win,
    current_tabpage = vim.api.nvim_get_current_tabpage,
    list_wins = vim.api.nvim_list_wins,
    win_valid = vim.api.nvim_win_is_valid,
    win_buf = vim.api.nvim_win_get_buf,
    set_win_buf = vim.api.nvim_win_set_buf,
    win_cursor = vim.api.nvim_win_get_cursor,
    set_win_cursor = vim.api.nvim_win_set_cursor,
    set_current_win = vim.api.nvim_set_current_win,
    win_tab = vim.api.nvim_win_get_tabpage,
    win_config = vim.api.nvim_win_get_config,
    editor_size = function()
      return { columns = vim.o.columns, lines = vim.o.lines }
    end,
    cursor = function(winid)
      local value = vim.api.nvim_win_get_cursor(winid)
      return { line = value[1] - 1, character = value[2] }
    end,
    getpos = function(winid)
      return vim.api.nvim_win_call(winid, function()
        return vim.fn.getpos(".")
      end)
    end,
    word_at_cursor = function(bufnr, winid)
      return vim.api.nvim_win_call(winid, function()
        assert(vim.api.nvim_get_current_buf() == bufnr)
        local line = vim.api.nvim_get_current_line()
        local col = vim.api.nvim_win_get_cursor(winid)[2]
        local search = 0
        while search <= #line do
          local match = vim.fn.matchstrpos(line, "\\k\\+", search)
          local text, start_col, end_col = match[1], match[2], match[3]
          if start_col < 0 then
            break
          end
          if start_col <= col and col < end_col then
            return text, start_col, end_col
          end
          search = math.max(end_col, search + 1)
        end
        return "", col, col
      end)
    end,
    word_at = function(lines, line, byte_col)
      local text = lines[line + 1]
      if text == nil or byte_col > #text then
        return nil
      end
      local left = text:sub(1, byte_col):match("[%w_]+$") or ""
      local right = text:sub(byte_col + 1):match("^[%w_]+") or ""
      local word = left .. right
      return word ~= "" and word or nil
    end,

    get_clients = vim.lsp.get_clients,
    make_position_params = vim.lsp.util.make_position_params,
    create_augroup = vim.api.nvim_create_augroup,
    delete_augroup = vim.api.nvim_del_augroup_by_id,
    create_autocmd = vim.api.nvim_create_autocmd,
    input = vim.ui.input,
    select = vim.ui.select,
    notify = vim.notify,
    defer = vim.defer_fn,
    timer = function(timeout_ms, on_timeout)
      local handle = assert(vim.uv.new_timer())
      local closed = false
      handle:start(timeout_ms, 0, vim.schedule_wrap(function()
        if not closed then
          on_timeout()
        end
      end))
      return {
        cancel = function()
          if not closed then
            handle:stop()
          end
        end,
        close = function()
          if closed then
            return
          end
          closed = true
          handle:stop()
          handle:close()
        end,
      }
    end,
  }
end

return M
