local M = {}
local Symbols = {}
Symbols.__index = Symbols

-- LSP SymbolKind numbers to lowercase names, per the protocol.
local kind_names = {
  "file",
  "module",
  "namespace",
  "package",
  "class",
  "method",
  "property",
  "field",
  "constructor",
  "enum",
  "interface",
  "function",
  "variable",
  "constant",
  "string",
  "number",
  "boolean",
  "array",
  "object",
  "key",
  "null",
  "enum_member",
  "struct",
  "event",
  "operator",
  "type_parameter",
}

-- Treesitter node types are grammar-specific; these ordered fragments cover
-- the common naming conventions across grammars.
local treesitter_kinds = {
  { "interface", "interface" },
  { "record", "record" },
  { "class", "class" },
  { "enum", "enum" },
  { "struct", "struct" },
  { "constructor", "constructor" },
  { "method", "method" },
  { "function", "function" },
  { "module", "module" },
  { "namespace", "namespace" },
}

function M.kind_name(kind)
  return type(kind) == "number" and kind_names[kind] or nil
end

local function position_in_range(position, range)
  if type(range) ~= "table" or type(range.start) ~= "table" or type(range["end"]) ~= "table" then
    return false
  end
  local after = position.line > range.start.line
    or (position.line == range.start.line and position.character >= range.start.character)
  local before = position.line < range["end"].line
    or (position.line == range["end"].line and position.character <= range["end"].character)
  return after and before
end

local function qualified(names)
  local tail = {}
  for index = math.max(1, #names - 1), #names do
    table.insert(tail, names[index])
  end
  if #tail == 0 then
    return nil
  end
  return table.concat(tail, ".")
end

-- Hierarchical DocumentSymbol[]: follow the deepest chain of symbols whose
-- range contains the position.
function M.from_document_symbols(symbols, position)
  local names = {}
  local kind
  local function descend(list)
    for _, symbol in ipairs(type(list) == "table" and list or {}) do
      if type(symbol) == "table" and type(symbol.name) == "string" and position_in_range(position, symbol.range) then
        table.insert(names, symbol.name)
        kind = M.kind_name(symbol.kind) or kind
        descend(symbol.children)
        return
      end
    end
  end
  descend(symbols)
  return qualified(names), kind
end

-- Flat SymbolInformation[]: pick the smallest range containing the position
-- and qualify with its container name.
function M.from_symbol_information(symbols, position)
  local best
  local function span(range)
    return (range["end"].line - range.start.line) * 1e6 + (range["end"].character - range.start.character)
  end
  for _, symbol in ipairs(type(symbols) == "table" and symbols or {}) do
    local range = type(symbol) == "table" and type(symbol.location) == "table" and symbol.location.range or nil
    if type(symbol.name) == "string" and range and position_in_range(position, range) then
      if not best or span(range) < span(best.location.range) then
        best = symbol
      end
    end
  end
  if not best then
    return nil, nil
  end
  local names = {}
  if type(best.containerName) == "string" and best.containerName ~= "" then
    table.insert(names, best.containerName)
  end
  table.insert(names, best.name)
  return qualified(names), M.kind_name(best.kind)
end

local function symbols_shape(result)
  if type(result) ~= "table" or type(result[1]) ~= "table" then
    return nil
  end
  if result[1].range ~= nil then
    return "hierarchical"
  end
  if result[1].location ~= nil then
    return "flat"
  end
end

function M.from_response(result, position)
  local shape = symbols_shape(result)
  if shape == "hierarchical" then
    return M.from_document_symbols(result, position)
  end
  if shape == "flat" then
    return M.from_symbol_information(result, position)
  end
  return nil, nil
end

local function treesitter_kind(node_type)
  for _, entry in ipairs(treesitter_kinds) do
    if node_type:find(entry[1], 1, true) then
      return entry[2]
    end
  end
end

function M.new(deps)
  assert(type(deps) == "table", "Voyager symbols dependencies are required")
  assert(type(deps.locator) == "table", "Voyager symbols require a locator")
  return setmetatable({
    _locator = deps.locator,
    _get_clients = deps.get_clients,
    _request_group = deps.request_group,
    _timer = deps.timer,
    _filetype_match = deps.filetype_match,
    _get_string_parser = deps.get_string_parser,
    _get_node_text = deps.get_node_text,
  }, Symbols)
end

function Symbols:_treesitter(location)
  local lines = self._locator:source(location.locator)
  if not lines then
    return nil, nil
  end
  local name = location.locator.path or location.locator.uri
  local lang = type(name) == "string" and self._filetype_match(name) or nil
  if not lang then
    return nil, nil
  end
  local source = table.concat(lines, "\n")
  local parsed, parser = pcall(self._get_string_parser, source, lang)
  if not parsed or not parser then
    return nil, nil
  end
  local trees = parser:parse()
  local tree = trees and trees[1]
  local root = tree and tree:root()
  if not root then
    return nil, nil
  end
  local position = location.range.start
  local node = root:named_descendant_for_range(position.line, position.character, position.line, position.character)
  local names = {}
  local kind
  while node do
    local name_field = node:field("name")
    local name_node = name_field and name_field[1]
    if name_node then
      local text_ok, text = pcall(self._get_node_text, name_node, source)
      if text_ok and type(text) == "string" and text ~= "" then
        table.insert(names, 1, text)
        kind = kind or treesitter_kind(node:type())
      end
    end
    node = node:parent()
  end
  return qualified(names), kind
end

function Symbols:_safe_treesitter(location)
  local ok, symbol, kind = pcall(self._treesitter, self, location)
  if ok then
    return symbol, kind
  end
  return nil, nil
end

local function group_requests(requests)
  local groups = {}
  for _, request in ipairs(requests) do
    if type(request.uri) == "string" and request.uri ~= "" then
      local group = groups[request.uri]
      if not group then
        group = { uri = request.uri, requests = {} }
        groups[request.uri] = group
      end
      table.insert(group.requests, request)
    end
  end
  return groups
end

-- Resolve enclosing symbols for `requests`, each { node_id, uri, location }.
-- Files whose buffer is open with a documentSymbol-capable client are asked
-- via LSP; everything else falls back to treesitter. `on_done` receives
-- { [node_id] = { symbol = ?, kind = ? } } containing only resolved entries.
function Symbols:resolve(requests, opts, on_done)
  assert(type(opts) == "table" and type(opts.timeout_ms) == "number", "Voyager symbols timeout is required")
  local groups = group_requests(requests or {})
  local results = {}
  local pending = 0
  local dispatching = true

  local function finish_group()
    pending = pending - 1
    if not dispatching and pending == 0 then
      on_done(results)
    end
  end

  local function apply(group, resolver)
    local resolved = 0
    for _, request in ipairs(group.requests) do
      local symbol, kind = resolver(request)
      if symbol or kind then
        results[request.node_id] = { symbol = symbol, kind = kind }
        resolved = resolved + 1
      end
    end
    return resolved
  end

  local function treesitter_group(group)
    return apply(group, function(request)
      return self:_safe_treesitter(request.location)
    end)
  end

  for _, group in pairs(groups) do
    pending = pending + 1
    local target = self._locator:list_target(group.requests[1].location.locator)
    local bufnr = type(target) == "table" and target.bufnr or nil
    local clients = bufnr and self._get_clients({ bufnr = bufnr, method = "textDocument/documentSymbol" }) or {}
    if #clients == 0 then
      treesitter_group(group)
      finish_group()
    else
      local snapshots = {}
      for _, client in ipairs(clients) do
        table.insert(snapshots, {
          id = client.id,
          name = client.name,
          offset_encoding = client.offset_encoding,
          client = client,
        })
      end
      local started, handle = pcall(self._request_group.start, {
        clients = snapshots,
        method = "textDocument/documentSymbol",
        bufnr = bufnr,
        timeout_ms = opts.timeout_ms,
        timer = self._timer,
        make_params = function()
          return { textDocument = { uri = group.uri } }
        end,
        on_complete = function(stage)
          local resolved = 0
          local response = (stage.responses or {})[1]
          if response then
            resolved = apply(group, function(request)
              return M.from_response(response.result, request.location.range.start)
            end)
          end
          if resolved == 0 then
            treesitter_group(group)
          end
          finish_group()
        end,
      })
      if not started or type(handle) ~= "table" then
        treesitter_group(group)
        finish_group()
      end
    end
  end

  dispatching = false
  if pending == 0 then
    on_done(results)
  end
end

return M
