local M = {}

local function find_root(path, marker)
  local current = vim.fs.normalize(path:gsub("\\", "/"), { expand_env = false })
  while current do
    if vim.uv.fs_stat(vim.fs.joinpath(current, marker)) then
      return current
    end
    local parent = vim.fs.dirname(current)
    if not parent or parent == current then
      return nil
    end
    current = parent
  end
end

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
    find_root = find_root,

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
      local loaded = {}
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
          local name = vim.api.nvim_buf_get_name(bufnr)
          if name == exact_name then
            return bufnr
          end
          table.insert(loaded, { bufnr = bufnr, name = name })
        end
      end
      local target_realpath = vim.uv.fs_realpath(exact_name)
      if target_realpath then
        for _, candidate in ipairs(loaded) do
          if vim.uv.fs_realpath(candidate.name) == target_realpath then
            return candidate.bufnr
          end
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
    open_folds = function(winid)
      vim.api.nvim_win_call(winid, function()
        vim.cmd("normal! zv")
      end)
    end,
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
    word_at_cursor = function(bufnr, winid)
      local result = vim.api.nvim_win_call(winid, function()
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
            return { text, start_col, end_col }
          end
          search = math.max(end_col, search + 1)
        end
        return { "", col, col }
      end)
      return result[1], result[2], result[3]
    end,
    word_at = function(lines, line, byte_col)
      local text = lines[line + 1]
      if text == nil or byte_col > #text then
        return nil
      end
      local search = 1
      while search <= #text do
        local start_byte, end_byte = text:find("[%w_]+", search)
        if not start_byte then
          return nil
        end
        if start_byte - 1 <= byte_col and byte_col < end_byte then
          return text:sub(start_byte, end_byte)
        end
        search = end_byte + 1
      end
    end,

    get_clients = vim.lsp.get_clients,
    make_position_params = vim.lsp.util.make_position_params,
    schedule = vim.schedule,
    filetype_match = function(name)
      return vim.filetype.match({ filename = name })
    end,
    uri_from_fname = vim.uri_from_fname,
    ts_string_parser = vim.treesitter.get_string_parser,
    ts_node_text = vim.treesitter.get_node_text,
    set_quickfix = function(list)
      vim.fn.setqflist({}, " ", list)
    end,
    flash_line = (function()
      local namespace = vim.api.nvim_create_namespace("voyager-flash")
      return function(bufnr, row)
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
        local marked = pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, row - 1, 0, {
          line_hl_group = "VoyagerFlash",
        })
        if marked then
          vim.defer_fn(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
              vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
            end
          end, 200)
        end
      end
    end)(),
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
      handle:start(
        timeout_ms,
        0,
        vim.schedule_wrap(function()
          if not closed then
            on_timeout()
          end
        end)
      )
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
