local encoding = assert(arg[1], "position encoding is required")
local root = assert(arg[2], "fixture root is required")
assert(encoding == "utf-8" or encoding == "utf-16", "unsupported fixture encoding")
root = vim.fs.normalize(root)

local function read_exact(length)
  local chunks = {}
  while length > 0 do
    local chunk = io.read(length)
    if chunk == nil or chunk == "" then
      return nil
    end
    table.insert(chunks, chunk)
    length = length - #chunk
  end
  return table.concat(chunks)
end

local function read_message()
  local length
  while true do
    local line = io.read("*l")
    if line == nil then
      return nil
    end
    line = line:gsub("\r$", "")
    if line == "" then
      break
    end
    length = tonumber(line:match("^[Cc]ontent%-[Ll]ength:%s*(%d+)")) or length
  end
  return vim.json.decode(assert(read_exact(assert(length, "missing Content-Length"))))
end

local function send(payload)
  local body = vim.json.encode(payload)
  io.write("Content-Length: " .. #body .. "\r\n\r\n" .. body)
  io.flush()
end

local function respond(id, result)
  send({ jsonrpc = "2.0", id = id, result = result == nil and vim.NIL or result })
end

local function respond_error(id, code, message)
  send({ jsonrpc = "2.0", id = id, error = { code = code, message = message } })
end

local files = {}
for _, filename in ipairs({ "main.lua", "mysql_store.lua", "memory_store.lua", "auth.lua" }) do
  local path = root .. "/lua/" .. filename
  local handle = assert(io.open(path, "rb"))
  local text = assert(handle:read("*a"))
  assert(handle:close())
  files[filename] = vim.split(text, "\n", { plain = true })
  if files[filename][#files[filename]] == "" then
    table.remove(files[filename])
  end
end

local function uri(filename)
  return vim.uri_from_fname(root .. "/lua/" .. filename)
end

local function protocol_character(line, byte_col)
  return vim.str_utfindex(line, encoding, byte_col, true)
end

local function find_range(filename, needle)
  for row, line in ipairs(assert(files[filename])) do
    local found = line:find(needle, 1, true)
    if found then
      local start_byte = found - 1
      local end_byte = start_byte + #needle
      return {
        start = { line = row - 1, character = protocol_character(line, start_byte) },
        ["end"] = { line = row - 1, character = protocol_character(line, end_byte) },
      }
    end
  end
  error(filename .. " missing " .. needle)
end

local function line_range(filename, selection)
  local line = files[filename][selection.start.line + 1]
  return {
    start = { line = selection.start.line, character = 0 },
    ["end"] = { line = selection.start.line, character = protocol_character(line, #line) },
  }
end

local function location(filename, needle)
  return { uri = uri(filename), range = find_range(filename, needle) }
end

local function location_link(filename, needle)
  local selection = find_range(filename, needle)
  return {
    targetUri = uri(filename),
    targetRange = line_range(filename, selection),
    targetSelectionRange = selection,
  }
end

local function hierarchy_item(filename, name)
  local selection = find_range(filename, name)
  return {
    name = name,
    kind = 12,
    detail = filename,
    uri = uri(filename),
    range = line_range(filename, selection),
    selectionRange = selection,
    data = { fixture = true, encoding = encoding, filename = filename },
  }
end

local function references(params)
  local document_uri = params.textDocument.uri
  if document_uri == uri("mysql_store.lua") then
    return { location("auth.lua", "mysql_store.save") }
  end
  if document_uri == uri("memory_store.lua") then
    return { location("auth.lua", "memory_store.save") }
  end
  return {
    location("auth.lua", "mysql_store.save"),
    location("auth.lua", "memory_store.save"),
  }
end

local function prepared(params)
  local document_uri = params.textDocument.uri
  if document_uri == uri("mysql_store.lua") then
    return { hierarchy_item("mysql_store.lua", "save") }
  end
  if document_uri == uri("memory_store.lua") then
    return { hierarchy_item("memory_store.lua", "save") }
  end
  if document_uri == uri("auth.lua") then
    return { hierarchy_item("auth.lua", "authorize") }
  end
  return { hierarchy_item("main.lua", "main") }
end

local function incoming_calls(params)
  local item = params.item
  if item.uri == uri("mysql_store.lua") then
    return { {
      from = hierarchy_item("auth.lua", "authorize"),
      fromRanges = { find_range("auth.lua", "mysql_store.save") },
    } }
  end
  if item.uri == uri("memory_store.lua") then
    return { {
      from = hierarchy_item("auth.lua", "authorize"),
      fromRanges = { find_range("auth.lua", "memory_store.save") },
    } }
  end
  if item.uri == uri("auth.lua") then
    return { {
      from = hierarchy_item("main.lua", "main"),
      fromRanges = { find_range("main.lua", "auth.authorize") },
    } }
  end
  return {}
end

local function outgoing_calls(params)
  local item = params.item
  if item.uri == uri("main.lua") then
    return {
      { to = hierarchy_item("mysql_store.lua", "save"), fromRanges = { find_range("main.lua", "mysql_store.save") } },
      { to = hierarchy_item("memory_store.lua", "save"), fromRanges = { find_range("main.lua", "memory_store.save") } },
      { to = hierarchy_item("auth.lua", "authorize"), fromRanges = { find_range("main.lua", "auth.authorize") } },
    }
  end
  if item.uri == uri("auth.lua") then
    return {
      { to = hierarchy_item("mysql_store.lua", "save"), fromRanges = { find_range("auth.lua", "mysql_store.save") } },
      { to = hierarchy_item("memory_store.lua", "save"), fromRanges = { find_range("auth.lua", "memory_store.save") } },
    }
  end
  return {}
end

local function action_result(method, params)
  if method == "textDocument/definition" then
    return true, location_link("auth.lua", "authorize")
  elseif method == "textDocument/declaration" then
    return true, location("auth.lua", "authorize")
  elseif method == "textDocument/references" then
    return true, references(params)
  elseif method == "textDocument/implementation" then
    return true, {
      location_link("mysql_store.lua", "save"),
      location("memory_store.lua", "save"),
    }
  elseif method == "textDocument/typeDefinition" then
    return true, location("auth.lua", "authorize")
  elseif method == "textDocument/prepareCallHierarchy" then
    return true, prepared(params)
  elseif method == "callHierarchy/incomingCalls" then
    return true, incoming_calls(params)
  elseif method == "callHierarchy/outgoingCalls" then
    return true, outgoing_calls(params)
  end
  return false
end

while true do
  local message = read_message()
  if message == nil then
    break
  end
  local method = message.method
  if method == "exit" then
    break
  elseif message.id == nil then
    -- Notifications need no response.
  elseif method == "initialize" then
    respond(message.id, {
      capabilities = {
        positionEncoding = encoding,
        textDocumentSync = 1,
        definitionProvider = true,
        declarationProvider = true,
        referencesProvider = true,
        implementationProvider = true,
        typeDefinitionProvider = true,
        callHierarchyProvider = true,
      },
      serverInfo = { name = "voyager-fixture-" .. encoding, version = "1" },
    })
  elseif method == "shutdown" then
    respond(message.id, nil)
  else
    local known, result = action_result(method, message.params or {})
    if known then
      respond(message.id, result)
    else
      respond_error(message.id, -32601, "method not found: " .. tostring(method))
    end
  end
end
