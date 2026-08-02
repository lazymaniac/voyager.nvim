local M = {}
local FakeFS = {}
FakeFS.__index = FakeFS

local function normalize(path)
  local value = path:gsub("\\", "/")
  return vim.fs.normalize(value, { expand_env = false })
end

local function parent(path)
  return vim.fs.dirname(path)
end

function M.new(spec)
  spec = spec or {}
  local self = setmetatable({
    files = {},
    _directories = {},
    _pid = spec.pid or 4321,
    _nonces = vim.deepcopy(spec.nonces or {}),
    _nonce_counter = 0,
    _next_fd = 10,
    _descriptors = {},
    _failure = nil,
    _short_write = nil,
    _operations = {},
  }, FakeFS)
  for path, content in pairs(spec.files or {}) do
    self.files[normalize(path)] = type(content) == "table" and table.concat(content, "\n") or content
  end
  for _, path in ipairs(spec.directories or {}) do
    self._directories[normalize(path)] = true
  end
  return self
end

function FakeFS:fail_next(operation, message)
  self._failure = { operation = operation, message = message }
end

function FakeFS:set_short_write(limit)
  self._short_write = limit
end

function FakeFS:_take_failure(operation)
  if self._failure and self._failure.operation == operation then
    local message = self._failure.message
    self._failure = nil
    return message
  end
end

function FakeFS:operation_names()
  return vim.deepcopy(self._operations)
end

function FakeFS:temp_paths()
  local paths = {}
  for path in pairs(self.files) do
    if path:find("%.tmp%-", 1) then
      table.insert(paths, path)
    end
  end
  table.sort(paths)
  return paths
end

function FakeFS:runtime()
  local fs = self
  return {
    now = function()
      return "2026-08-01T20:00:00Z"
    end,
    random = function(length)
      local value = table.remove(fs._nonces, 1)
      if not value then
        fs._nonce_counter = fs._nonce_counter + 1
        value = string.rep(string.char((fs._nonce_counter % 255) + 1), length)
      end
      if #value < length then
        value = value .. string.rep("\0", length - #value)
      end
      return value:sub(1, length)
    end,
    sha256 = vim.fn.sha256,
    pid = function()
      return fs._pid
    end,
    cwd = function()
      return "/project"
    end,
    dirname = parent,
    find_root = function(path, marker)
      local current = parent(normalize(path))
      while current do
        if fs._directories[current .. "/" .. marker] then
          return current
        end
        local next_parent = parent(current)
        if not next_parent or next_parent == current then
          break
        end
        current = next_parent
      end
    end,
    fs_realpath = function(path)
      return normalize(path)
    end,
    fs_stat = function(path)
      path = normalize(path)
      if fs._directories[path] then
        return { type = "directory" }
      end
      if fs.files[path] ~= nil then
        return { type = "file", size = #fs.files[path] }
      end
    end,
    fs_scandir = function(path)
      path = normalize(path)
      if not fs._directories[path] then
        return nil, "directory not found"
      end
      local prefix = path == "/" and "/" or path .. "/"
      local entries = {}
      local seen = {}
      local function add(candidate, kind)
        if candidate:sub(1, #prefix) ~= prefix then
          return
        end
        local remainder = candidate:sub(#prefix + 1)
        if remainder ~= "" and not remainder:find("/", 1, true) and not seen[remainder] then
          seen[remainder] = true
          table.insert(entries, { name = remainder, kind = kind })
        end
      end
      for candidate in pairs(fs._directories) do
        add(candidate, "directory")
      end
      for candidate in pairs(fs.files) do
        add(candidate, "file")
      end
      table.sort(entries, function(a, b)
        return a.name < b.name
      end)
      return { entries = entries, index = 0 }
    end,
    fs_scandir_next = function(handle)
      handle.index = handle.index + 1
      local entry = handle.entries[handle.index]
      if entry then
        return entry.name, entry.kind
      end
    end,
    fs_open = function(path, mode)
      local failure = fs:_take_failure("fs_open")
      if failure then
        return nil, failure
      end
      path = normalize(path)
      if mode == "r" and fs.files[path] == nil then
        return nil, "file not found"
      end
      if mode ~= "r" then
        fs.files[path] = ""
      end
      local fd = fs._next_fd
      fs._next_fd = fd + 1
      fs._descriptors[fd] = { path = path, mode = mode }
      return fd
    end,
    fs_read = function(fd, size, offset)
      local descriptor = fs._descriptors[fd]
      if not descriptor then
        return nil, "bad descriptor"
      end
      return fs.files[descriptor.path]:sub(offset + 1, offset + size)
    end,
    fs_write = function(fd, data, offset)
      local failure = fs:_take_failure("fs_write")
      if failure then
        return nil, failure
      end
      local descriptor = fs._descriptors[fd]
      if not descriptor then
        return nil, "bad descriptor"
      end
      local count = math.min(#data, fs._short_write or #data)
      local chunk = data:sub(1, count)
      local current = fs.files[descriptor.path] or ""
      fs.files[descriptor.path] = current:sub(1, offset) .. chunk .. current:sub(offset + count + 1)
      table.insert(fs._operations, "write")
      return count
    end,
    fs_fsync = function(fd)
      local failure = fs:_take_failure("fs_fsync")
      if failure then
        return nil, failure
      end
      if not fs._descriptors[fd] then
        return nil, "bad descriptor"
      end
      table.insert(fs._operations, "fsync")
      return true
    end,
    fs_close = function(fd)
      local failure = fs:_take_failure("fs_close")
      if failure then
        return nil, failure
      end
      local descriptor = fs._descriptors[fd]
      if not descriptor then
        return nil, "bad descriptor"
      end
      fs._descriptors[fd] = nil
      if descriptor.mode ~= "r" then
        table.insert(fs._operations, "close")
      end
      return true
    end,
    fs_rename = function(source, target)
      local failure = fs:_take_failure("fs_rename")
      if failure then
        return nil, failure
      end
      source = normalize(source)
      target = normalize(target)
      if fs.files[source] == nil then
        return nil, "source not found"
      end
      fs.files[target] = fs.files[source]
      fs.files[source] = nil
      table.insert(fs._operations, "rename")
      return true
    end,
    fs_unlink = function(path)
      local failure = fs:_take_failure("fs_unlink")
      if failure then
        return nil, failure
      end
      path = normalize(path)
      fs.files[path] = nil
      table.insert(fs._operations, "unlink")
      return true
    end,
    mkdir = function(path)
      path = normalize(path)
      local additions = {}
      while path and path ~= "." and not fs._directories[path] do
        table.insert(additions, path)
        local next_parent = parent(path)
        if not next_parent or next_parent == path then
          break
        end
        path = next_parent
      end
      for _, directory in ipairs(additions) do
        fs._directories[directory] = true
      end
      return 1
    end,
    read_file = function(path)
      path = normalize(path)
      local content = fs.files[path]
      if content == nil then
        return nil, "file not found"
      end
      return vim.split(content, "\n", { plain = true, trimempty = true })
    end,
    buffer_name = function()
      return "/project/lua/main.lua"
    end,
    find_buffer = function()
      return nil
    end,
    buffer_valid = function()
      return false
    end,
    buffer_loaded = function()
      return false
    end,
    get_buffer_lines = function()
      return {}
    end,
    word_at = function()
      return nil
    end,
  }
end

return M
