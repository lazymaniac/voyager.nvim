local Locator = require("voyager.locator")

local M = {}
local Store = {}
Store.__index = Store

local persisted_keys = {
  "schema_version",
  "position_encoding",
  "revision",
  "flow_id",
  "name",
  "root_key",
  "created_at",
  "updated_at",
  "current_node_id",
  "root",
}

local function normalize(path)
  local value = path:gsub("\\", "/")
  return vim.fs.normalize(value)
end

local function trim_root(path)
  if path == "/" then
    return path
  end
  return path:gsub("/+$", "")
end

local function contains(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function hex(bytes)
  return bytes:gsub(".", function(byte)
    return string.format("%02x", string.byte(byte))
  end)
end

local function document_from_flow(flow)
  local document = {}
  for _, key in ipairs(persisted_keys) do
    document[key] = vim.deepcopy(flow[key])
  end
  return document
end

local function strip_transient_node_state(node)
  node.stale = nil
  node.stale_reason = nil
  local children = node.kind == "location" and node.actions or node.results
  for _, child in ipairs(children) do
    strip_transient_node_state(child)
  end
end

local function node_count(node)
  local total = 1
  local children = node.kind == "location" and node.actions or node.results
  for _, child in ipairs(children) do
    total = total + node_count(child)
  end
  return total
end

function M.new(opts)
  assert(type(opts) == "table", "Voyager store options are required")
  assert(type(opts.runtime) == "table", "Voyager store runtime is required")
  assert(type(opts.schema) == "table", "Voyager store schema is required")
  assert(type(opts.flow) == "table", "Voyager store flow module is required")
  return setmetatable({
    _runtime = opts.runtime,
    _schema = opts.schema,
    _locator = opts.locator,
    _flow = opts.flow,
    _project_root = type(opts.locator) == "table" and opts.locator._project_root or nil,
  }, Store)
end

function Store:_realpath(path)
  local normalized = normalize(path)
  local resolved = self._runtime.fs_realpath(normalized)
  return trim_root(normalize(resolved or normalized))
end

function Store:project_root(bufnr, clients, cwd)
  local file = self:_realpath(self._runtime.buffer_name(bufnr))
  local roots = {}
  for _, client in ipairs(clients or {}) do
    local root = client.config and client.config.root_dir
    if type(root) == "string" and root ~= "" then
      root = self:_realpath(root)
      if contains(file, root) then
        table.insert(roots, root)
      end
    end
  end
  table.sort(roots, function(left, right)
    return #left > #right
  end)
  if roots[1] then
    return roots[1]
  end

  local git_root = self._runtime.find_root(file, ".git")
  if git_root then
    return self:_realpath(git_root)
  end

  local current = self:_realpath(cwd)
  if contains(file, current) then
    return current
  end
  return self:_realpath(self._runtime.dirname(file))
end

function Store:_flows_dir(project_root)
  return trim_root(normalize(project_root)) .. "/.voyager/flows"
end

function Store:_read_text(path)
  local lines, err = self._runtime.read_file(path)
  if not lines then
    return nil, err
  end
  if type(lines) == "string" then
    return lines
  end
  return table.concat(lines, "\n")
end

function Store:_path_for_length(flow, length)
  local stem = Locator.slug(flow.name) .. "-" .. flow.root_key:sub(1, length)
  return self:_flows_dir(assert(self._project_root, "Voyager store has no fixed project root"))
    .. "/"
    .. stem
    .. ".json"
end

function Store:path_for(flow)
  local suffix = type(flow.flow_id) == "string" and flow.flow_id:match("%-([0-9a-f]+)$") or nil
  local minimum = suffix and #suffix or 8
  for _, length in ipairs({ 8, 16, 64 }) do
    if length >= minimum then
      local path = self:_path_for_length(flow, length)
      if not self._runtime.fs_stat(path) then
        return path
      end
      local text = self:_read_text(path)
      local ok, document = pcall(self._schema.decode, text)
      if ok and document.root_key == flow.root_key then
        return path
      end
      if length == 64 then
        return path
      end
    end
  end
  error("Voyager could not resolve a flow path", 0)
end

function Store:_write_atomic(path, encoded)
  local runtime = self._runtime
  local nonce, nonce_error = runtime.random(8)
  if not nonce then
    return nil, nonce_error or "entropy unavailable"
  end
  local filename = path:match("([^/]+)$")
  local temp = runtime.dirname(path) .. "/." .. filename .. ".tmp-" .. runtime.pid() .. "-" .. hex(nonce)
  local fd

  local ok, failure = pcall(function()
    local open_error
    fd, open_error = runtime.fs_open(temp, "w", 384)
    if not fd then
      error(open_error or "fs_open failed", 0)
    end
    local offset = 0
    while offset < #encoded do
      local written, write_error = runtime.fs_write(fd, encoded:sub(offset + 1), offset)
      if not written or written <= 0 then
        error(write_error or "fs_write failed", 0)
      end
      offset = offset + written
    end
    local synced, sync_error = runtime.fs_fsync(fd)
    if not synced then
      error(sync_error or "fs_fsync failed", 0)
    end
    local closed, close_error = runtime.fs_close(fd)
    if not closed then
      error(close_error or "fs_close failed", 0)
    end
    fd = nil
    local renamed, rename_error = runtime.fs_rename(temp, path)
    if not renamed then
      error(rename_error or "fs_rename failed", 0)
    end
  end)

  if not ok then
    if fd then
      pcall(runtime.fs_close, fd)
    end
    if runtime.fs_stat(temp) then
      pcall(runtime.fs_unlink, temp)
    end
    return nil, tostring(failure)
  end
  return true
end

function Store:save(flow)
  local project_root = assert(self._project_root, "Voyager store has no fixed project root")
  self._runtime.mkdir(self:_flows_dir(project_root))
  local path = self:path_for(flow)
  local latest
  if self._runtime.fs_stat(path) then
    local text, read_error = self:_read_text(path)
    if not text then
      return nil, read_error
    end
    local ok, decoded = pcall(self._schema.decode, text)
    if not ok then
      return nil, tostring(decoded)
    end
    latest = decoded
  end

  local merged
  if latest then
    local ok, result = pcall(self._flow.merge, latest, flow, flow:journal(), flow._next_id)
    if not ok then
      return nil, tostring(result)
    end
    merged = result
  else
    merged = document_from_flow(flow)
    merged.revision = 1
  end
  merged.updated_at = self._runtime.now()
  merged.name = Locator.flow_name(merged.root.location)
  merged.root_key = Locator.root_key(merged.root.location)
  merged.flow_id = path:match("/([^/]+)%.json$")
  strip_transient_node_state(merged.root)

  local ok, encoded = pcall(self._schema.encode, merged)
  if not ok then
    return nil, tostring(encoded)
  end
  local written, write_error = self:_write_atomic(path, encoded)
  if not written then
    return nil, write_error
  end
  flow:mark_saved(merged)
  return merged
end

function Store:list(project_root)
  local directory = self:_flows_dir(project_root)
  local stat = self._runtime.fs_stat(directory)
  if not stat or stat.type ~= "directory" then
    return {}, {}
  end
  local handle, scan_error = self._runtime.fs_scandir(directory)
  if not handle then
    return {}, { "Voyager: cannot scan " .. directory .. ": " .. tostring(scan_error) }
  end
  local entries = {}
  local warnings = {}
  while true do
    local name, kind = self._runtime.fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "file" and name:sub(-5) == ".json" then
      local path = directory .. "/" .. name
      local text, read_error = self:_read_text(path)
      local ok, document = false, nil
      if text then
        ok, document = pcall(self._schema.decode, text)
      end
      if not text or not ok then
        table.insert(warnings, "Voyager: skipped " .. path .. ": " .. tostring(read_error or document))
      elseif name ~= document.flow_id .. ".json" then
        table.insert(warnings, "Voyager: skipped " .. path .. ": filename does not match flow identity")
      else
        table.insert(entries, {
          path = path,
          name = document.name,
          display_path = document.root.location.locator.path or document.root.location.locator.uri,
          updated_at = document.updated_at,
          document = document,
        })
      end
    end
  end
  table.sort(entries, function(left, right)
    if left.updated_at ~= right.updated_at then
      return left.updated_at > right.updated_at
    end
    if left.name ~= right.name then
      return left.name < right.name
    end
    return left.display_path < right.display_path
  end)
  return entries, warnings
end

function Store:load(entry_or_path, project_root)
  local path = type(entry_or_path) == "table" and entry_or_path.path or entry_or_path
  if type(path) ~= "string" then
    return nil, "Voyager load requires a saved-flow path"
  end
  local directory = self:_flows_dir(project_root or self._project_root)
  path = normalize(path)
  if self._runtime.dirname(path) ~= directory or path:sub(-5) ~= ".json" then
    return nil, "Voyager load path is outside the fixed flows directory"
  end
  local text, read_error = self:_read_text(path)
  if not text then
    return nil, read_error
  end
  local ok, document = pcall(self._schema.decode, text)
  if not ok then
    return nil, tostring(document)
  end
  if path:match("([^/]+)$") ~= document.flow_id .. ".json" then
    return nil, "Voyager saved-flow filename does not match its identity"
  end
  local nonce, nonce_error = self._runtime.random(16)
  if not nonce then
    return nil, nonce_error or "entropy unavailable"
  end
  local flow = self._flow.from_document(document, {
    now = self._runtime.now,
    next_id = Locator.id_factory(document.flow_id, nonce, node_count(document.root), self._runtime.sha256),
  })
  if type(self._locator) == "table" and type(self._locator.is_stale) == "function" then
    for _, node in ipairs(flow:dfs()) do
      if node.kind == "location" then
        local stale, reason = self._locator:is_stale(node.location)
        node.stale = stale
        node.stale_reason = stale and reason or nil
      end
    end
  end
  return flow
end

return M
