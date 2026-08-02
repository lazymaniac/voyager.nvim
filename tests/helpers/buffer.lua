local M = {}

local function normalize(path)
  local normalized = path:gsub("\\", "/")
  return vim.fs.normalize(normalized, { expand_env = false })
end

function M.new(spec)
  spec = spec or {}
  local env = {
    buffers = vim.deepcopy(spec.buffers or {}),
    files = vim.deepcopy(spec.files or {}),
  }

  local function call(name)
    table.insert(env.runtime.calls, name)
  end

  local function buffer_by_id(bufnr)
    for _, buffer in ipairs(env.buffers) do
      if buffer.id == bufnr then
        return buffer
      end
    end
  end

  local function next_buffer_id()
    local highest = 0
    for _, buffer in ipairs(env.buffers) do
      highest = math.max(highest, buffer.id)
    end
    return highest + 1
  end

  env.runtime = {
    calls = {},
    fs_realpath = function(path)
      return normalize(path)
    end,
    fs_stat = function(path)
      path = normalize(path)
      if env.files[path] then
        return { type = "file" }
      end
    end,
    read_file = function(path)
      path = normalize(path)
      call("read_file:" .. path)
      local lines = env.files[path]
      if not lines then
        return nil, "file not found"
      end
      return vim.deepcopy(lines)
    end,
    find_buffer = function(name)
      call("find_buffer:" .. name)
      for _, buffer in ipairs(env.buffers) do
        if buffer.name == name and buffer.valid ~= false and buffer.loaded == true then
          return buffer.id
        end
      end
    end,
    buffer_valid = function(bufnr)
      local buffer = buffer_by_id(bufnr)
      return buffer ~= nil and buffer.valid ~= false
    end,
    buffer_loaded = function(bufnr)
      local buffer = buffer_by_id(bufnr)
      return buffer ~= nil and buffer.loaded == true
    end,
    buffer_name = function(bufnr)
      local buffer = assert(buffer_by_id(bufnr))
      return buffer.name
    end,
    get_buffer_lines = function(bufnr)
      call("get_buffer_lines:" .. bufnr)
      return vim.deepcopy(assert(buffer_by_id(bufnr)).lines or {})
    end,
    add_buffer = function(name)
      call("add_buffer:" .. name)
      local id = next_buffer_id()
      table.insert(env.buffers, { id = id, name = name, valid = true, loaded = false, listed = false, lines = {} })
      return id
    end,
    load_buffer = function(bufnr)
      call("load_buffer:" .. bufnr)
      local buffer = assert(buffer_by_id(bufnr))
      local lines = env.files[normalize(buffer.name)]
      if not lines then
        return false, "file not found"
      end
      buffer.lines = vim.deepcopy(lines)
      buffer.loaded = true
      return true
    end,
    set_buffer_listed = function(bufnr, listed)
      call("set_buffer_listed:" .. bufnr)
      assert(buffer_by_id(bufnr)).listed = listed
    end,
    cursor = function()
      return vim.deepcopy(spec.cursor or { line = 0, character = 0 })
    end,
    word_at_cursor = function()
      local word = spec.cursor_word or "symbol"
      local cursor = spec.cursor or { line = 0, character = 0 }
      return word, cursor.character, cursor.character + #word
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
    random = function(length)
      return string.rep("\1", length)
    end,
    sha256 = vim.fn.sha256,
  }

  return env
end

return M
