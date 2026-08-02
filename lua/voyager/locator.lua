local M = {}

local function canonical_json(value)
  return vim.json.encode(value)
end

local function normalize_path(path)
  local normalized = path:gsub("\\", "/")
  return vim.fs.normalize(normalized, { expand_env = false })
end

local function real_path(runtime, path)
  local normalized = normalize_path(path)
  local resolved = runtime.fs_realpath(normalized)
  return normalize_path(resolved or normalized)
end

local function trim_root(path)
  if path == "/" then
    return path
  end
  return path:gsub("/+$", "")
end

local function path_is_within(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function basename(locator)
  local value = locator.path or locator.uri or "anonymous"
  value = value:gsub("\\", "/"):gsub("/+$", "")
  return value:match("([^/]+)$") or "anonymous"
end

function M.canonical_range(lines, range, encoding)
  if
    type(lines) ~= "table"
    or type(range) ~= "table"
    or type(range.start) ~= "table"
    or type(range["end"]) ~= "table"
    or (encoding ~= "utf-8" and encoding ~= "utf-16" and encoding ~= "utf-32")
  then
    return nil, "range, source lines, or position encoding is invalid"
  end
  local function position(value)
    if
      type(value) ~= "table"
      or type(value.line) ~= "number"
      or value.line % 1 ~= 0
      or value.line < 0
      or type(value.character) ~= "number"
      or value.character % 1 ~= 0
      or value.character < 0
    then
      return nil, "position must contain non-negative integer line and character"
    end
    local line = lines[value.line + 1]
    if line == nil then
      return nil, "line is outside source bounds"
    end
    local ok, byte = pcall(vim.str_byteindex, line, encoding, value.character, true)
    if not ok or byte < 0 or byte > #line then
      return nil, "character is outside source bounds"
    end
    local roundtrip_ok, character = pcall(vim.str_utfindex, line, encoding, byte, true)
    if not roundtrip_ok or character ~= value.character then
      return nil, "character is not on an encoding boundary"
    end
    return { line = value.line, character = byte }
  end

  local start_pos, start_error = position(range.start)
  if not start_pos then
    return nil, start_error
  end
  local end_pos, end_error = position(range["end"])
  if not end_pos then
    return nil, end_error
  end
  if end_pos.line < start_pos.line or (end_pos.line == start_pos.line and end_pos.character < start_pos.character) then
    return nil, "range end precedes range start"
  end
  return { start = start_pos, ["end"] = end_pos }
end

function M.locator_key(locator)
  return canonical_json({ locator.kind, locator.path or locator.uri })
end

function M.location_key(location)
  local range = location.range
  return canonical_json({
    location.locator.kind,
    location.locator.path or location.locator.uri,
    range.start.line,
    range.start.character,
    range["end"].line,
    range["end"].character,
  })
end

function M.contains(location, locator, cursor)
  if M.locator_key(location.locator) ~= M.locator_key(locator) then
    return false
  end
  local range = location.range
  if range.start.line == range["end"].line and range.start.character == range["end"].character then
    return cursor.line == range.start.line and cursor.character == range.start.character
  end
  local after_start = cursor.line > range.start.line
    or (cursor.line == range.start.line and cursor.character >= range.start.character)
  local before_end = cursor.line < range["end"].line
    or (cursor.line == range["end"].line and cursor.character < range["end"].character)
  return after_start and before_end
end

local Locator = {}
Locator.__index = Locator

function M.new(runtime, project_root, resolve_uri)
  assert(type(runtime) == "table", "Voyager locator requires a runtime")
  local root = trim_root(real_path(runtime, project_root))
  return setmetatable({
    _runtime = runtime,
    _project_root = root,
    _resolve_uri = resolve_uri,
  }, Locator)
end

function Locator:_file_path(locator)
  if type(locator) ~= "table" or type(locator.kind) ~= "string" then
    return nil, "locator is invalid"
  end
  if locator.kind == "project" and type(locator.path) == "string" then
    local path = real_path(self._runtime, self._project_root .. "/" .. locator.path:gsub("\\", "/"))
    if not path_is_within(path, self._project_root) then
      return nil, "project locator escapes project root"
    end
    return path
  end
  if locator.kind == "absolute" and type(locator.path) == "string" then
    return real_path(self._runtime, locator.path)
  end
  return nil, "locator is not a file"
end

function Locator:from_uri(uri)
  if type(uri) ~= "string" or uri == "" then
    return nil, "URI must be a non-empty string"
  end
  if uri:sub(1, 7):lower() ~= "file://" then
    return { kind = "uri", uri = uri }
  end
  local ok, filename = pcall(vim.uri_to_fname, uri)
  if not ok then
    return nil, "file URI is invalid"
  end
  local path = real_path(self._runtime, filename)
  if path_is_within(path, self._project_root) then
    local relative = path == self._project_root and "." or path:sub(#self._project_root + 2)
    return { kind = "project", path = relative:gsub("\\", "/") }
  end
  return { kind = "absolute", path = path }
end

function Locator:_uri_buffer(locator)
  local runtime = self._runtime
  local bufnr = runtime.find_buffer(locator.uri)
  if bufnr then
    return bufnr
  end
  if self._resolve_uri then
    local ok, resolved = pcall(self._resolve_uri, locator.uri)
    if
      ok
      and type(resolved) == "number"
      and resolved % 1 == 0
      and runtime.buffer_valid(resolved)
      and runtime.buffer_loaded(resolved)
    then
      return resolved
    end
  end
end

function Locator:source(locator)
  local runtime = self._runtime
  if type(locator) == "table" and locator.kind == "uri" and type(locator.uri) == "string" then
    local bufnr = self:_uri_buffer(locator)
    if not bufnr then
      return nil, "non-file URI has no loaded source"
    end
    return runtime.get_buffer_lines(bufnr)
  end

  local path, path_error = self:_file_path(locator)
  if not path then
    return nil, path_error
  end
  local bufnr = runtime.find_buffer(path)
  if bufnr then
    return runtime.get_buffer_lines(bufnr)
  end
  return runtime.read_file(path)
end

function Locator:list_target(locator)
  if type(locator) == "table" and locator.kind == "uri" and type(locator.uri) == "string" then
    local bufnr = self:_uri_buffer(locator)
    if not bufnr then
      return nil, "non-file URI has no loaded source"
    end
    return { bufnr = bufnr }
  end
  local path, reason = self:_file_path(locator)
  if not path then
    return nil, reason
  end
  local bufnr = self._runtime.find_buffer(path)
  if bufnr then
    return { bufnr = bufnr }
  end
  return { filename = path }
end

function Locator:metadata(locator, lines, range, preferred_symbol)
  local symbol
  if type(preferred_symbol) == "string" and vim.trim(preferred_symbol) ~= "" then
    symbol = preferred_symbol
  else
    symbol = self._runtime.word_at(lines, range.start.line, range.start.character)
  end
  if not symbol or symbol == "" then
    symbol = string.format("%s:%d", basename(locator), range.start.line + 1)
  end
  local context = lines[range.start.line + 1]
  if context == "" then
    context = nil
  end
  return symbol, context
end

function Locator:is_stale(location)
  if type(location) ~= "table" or type(location.range) ~= "table" then
    return true, "location is invalid"
  end
  local lines, source_error = self:source(location.locator)
  if not lines then
    return true, source_error
  end
  local normalized, range_error = M.canonical_range(lines, location.range, "utf-8")
  if not normalized or not vim.deep_equal(normalized, location.range) then
    return true, range_error or "location range is invalid"
  end
  return false
end

function Locator:open_target(location)
  local stale, stale_reason = self:is_stale(location)
  if stale then
    return nil, stale_reason
  end

  local runtime = self._runtime
  local bufnr
  if location.locator.kind == "uri" then
    bufnr = self:_uri_buffer(location.locator)
    if not bufnr then
      return nil, "non-file URI has no loaded source"
    end
  else
    local path, path_error = self:_file_path(location.locator)
    if not path then
      return nil, path_error
    end
    bufnr = runtime.find_buffer(path)
    if not bufnr then
      bufnr = runtime.add_buffer(path)
      local loaded, load_error = runtime.load_buffer(bufnr)
      if not loaded then
        return nil, load_error
      end
    end
  end
  runtime.set_buffer_listed(bufnr, true)
  return {
    bufnr = bufnr,
    row = location.range.start.line + 1,
    col = location.range.start.character,
  }
end

function M.capture_root(bufnr, winid, project_root, runtime)
  local locator_service = M.new(runtime, project_root, nil)
  local name = runtime.buffer_name(bufnr)
  local ok, uri = pcall(vim.uri_from_fname, name)
  if not ok then
    return nil, "root buffer name is invalid"
  end
  local locator, locator_error = locator_service:from_uri(uri)
  if not locator then
    return nil, locator_error
  end
  local cursor = runtime.cursor(winid)
  local word, start_col, end_col = runtime.word_at_cursor(bufnr, winid)
  word = type(word) == "string" and vim.trim(word) or ""
  if word == "" then
    word = "<anonymous>"
    start_col = cursor.character
    end_col = cursor.character
  end
  local lines = runtime.get_buffer_lines(bufnr)
  local context = lines[cursor.line + 1]
  if context == "" then
    context = nil
  end
  return {
    locator = locator,
    range = {
      start = { line = cursor.line, character = start_col },
      ["end"] = { line = cursor.line, character = end_col },
    },
    symbol = word,
    context = context,
  }
end

function M.root_key(root)
  local range = root.range
  return vim.fn.sha256(canonical_json({
    root.locator.kind,
    root.locator.path or root.locator.uri,
    root.symbol,
    range.start.line,
    range.start.character,
  }))
end

function M.flow_name(root)
  local symbol = type(root.symbol) == "string" and vim.trim(root.symbol) or ""
  if symbol ~= "" and symbol ~= "<anonymous>" then
    return symbol
  end
  return string.format("%s:%d", basename(root.locator), root.range.start.line + 1)
end

function M.slug(name)
  local folded = name:gsub("Ç", "C"):gsub("ç", "c")
  folded = folded:gsub("[A-Z]", string.lower)
  local slug = folded:gsub("[^a-z0-9]+", "-"):gsub("^-+", ""):gsub("-+$", "")
  slug = slug:sub(1, 48):gsub("-+$", "")
  return slug ~= "" and slug or "anonymous"
end

function M.flow_id(root, hash_length)
  return M.slug(M.flow_name(root)) .. "-" .. M.root_key(root):sub(1, hash_length)
end

function M.id_factory(flow_id, nonce_bytes, initial_counter, sha256)
  local nonce_hex = nonce_bytes:gsub(".", function(byte)
    return string.format("%02x", string.byte(byte))
  end)
  local counter = initial_counter or 0
  return function(kind)
    assert(kind == "location" or kind == "action", "unknown Voyager node kind: " .. tostring(kind))
    counter = counter + 1
    local prefix = kind == "location" and "loc" or "action"
    local digest = sha256(flow_id .. "\0" .. nonce_hex .. "\0" .. kind .. "\0" .. tostring(counter))
    return prefix .. "-" .. digest:sub(1, 32)
  end
end

return M
