local Locator = require("voyager.locator")
local Symbols = require("voyager.symbols")

local M = {}
local Normalize = {}
Normalize.__index = Normalize

local function failure(client, response_index, invalid_item_count)
  return {
    kind = "normalization",
    client_id = client.id,
    client_name = client.name,
    response_index = response_index,
    invalid_item_count = invalid_item_count,
    message = string.format(
      "%d LSP response item%s could not be normalized",
      invalid_item_count,
      invalid_item_count == 1 and "" or "s"
    ),
  }
end

local function empty_summary()
  return {
    usable_response_count = 0,
    empty_response_count = 0,
    invalid_response_count = 0,
  }
end

local function raw_items(result)
  if result == nil then
    return {}, true
  end
  if type(result) == "table" and next(result) == nil then
    return {}, true
  end
  if type(result) == "table" and (result.uri ~= nil or result.targetUri ~= nil) then
    return { result }, false
  end
  if type(result) == "table" and #result > 0 then
    local copy = {}
    for index = 1, #result do
      table.insert(copy, result[index])
    end
    return copy, false
  end
  return { result }, false
end

local function protocol_location(raw)
  if type(raw) ~= "table" then
    return nil
  end
  if raw.targetUri ~= nil then
    return raw.targetUri, raw.targetSelectionRange or raw.targetRange
  end
  return raw.uri, raw.range
end

local function add_unique(unique, seen, location)
  if not seen[location.identity] then
    seen[location.identity] = true
    table.insert(unique, vim.deepcopy(location))
  end
end

function M.new(opts)
  assert(type(opts) == "table" and type(opts.locator) == "table", "Voyager normalizer requires a locator")
  return setmetatable({ _locator = opts.locator }, Normalize)
end

function Normalize:is_project_uri(uri)
  local ok, result = pcall(self._locator.is_project_uri, self._locator, uri)
  if not ok then
    return nil
  end
  return result
end

function Normalize:_item(client, raw, uri, protocol_range, preferred_symbol, response_index, range_index)
  if type(uri) ~= "string" or type(protocol_range) ~= "table" then
    return nil
  end
  local locator = self._locator:from_uri(uri)
  if not locator then
    return nil
  end
  local lines = self._locator:source(locator)
  if not lines then
    return nil
  end
  local canonical_range = Locator.canonical_range(lines, protocol_range, client.offset_encoding)
  if not canonical_range then
    return nil
  end
  local symbol, context = self._locator:metadata(locator, lines, canonical_range, preferred_symbol)
  local list_target = self._locator:list_target(locator)
  if not list_target then
    return nil
  end

  local location = {
    locator = locator,
    range = canonical_range,
    symbol = symbol,
    context = context ~= "" and context or nil,
  }
  location.identity = Locator.location_key(location)

  local list_item = vim.tbl_extend("force", vim.deepcopy(list_target), {
    lnum = canonical_range.start.line + 1,
    col = canonical_range.start.character + 1,
    end_lnum = canonical_range["end"].line + 1,
    end_col = canonical_range["end"].character + 1,
    text = lines[canonical_range.start.line + 1],
  })
  return {
    identity = location.identity,
    location = location,
    raw = raw,
    client_id = client.id,
    client_name = client.name,
    offset_encoding = client.offset_encoding,
    response_index = response_index,
    range_index = range_index,
    list_item = list_item,
  }
end

function Normalize:_safe_item(...)
  local ok, item = pcall(self._item, self, ...)
  return ok and item or nil
end

-- Call-hierarchy results are presented and jumped to at their call sites, but
-- future hierarchy requests must prepare the caller/callee symbol represented
-- by the row. Keep that protocol selection range as a separate canonical
-- UTF-8 anchor so the two positions do not get conflated.
function Normalize:_query_anchor(client, item)
  if type(item) ~= "table" or type(item.uri) ~= "string" or item.uri == "" or type(item.selectionRange) ~= "table" then
    return nil
  end
  local locator = self._locator:from_uri(item.uri)
  if not locator then
    return nil
  end
  local lines = self._locator:source(locator)
  if not lines then
    return nil
  end
  local range = Locator.canonical_range(lines, item.selectionRange, client.offset_encoding)
  if not range then
    return nil
  end
  local line_text = lines[range.start.line + 1]
  if type(line_text) ~= "string" or line_text == "" then
    return nil
  end
  return { locator = locator, range = range, line_text = line_text }
end

function Normalize:_safe_query_anchor(...)
  local ok, anchor = pcall(self._query_anchor, self, ...)
  return ok and anchor or nil
end

function Normalize:locations(responses)
  local sorted = {}
  for _, response in ipairs(responses or {}) do
    table.insert(sorted, response)
  end
  table.sort(sorted, function(left, right)
    if left.client.name == right.client.name then
      return left.client.id < right.client.id
    end
    return left.client.name < right.client.name
  end)

  local presentation = {}
  local unique = {}
  local seen = {}
  local failures = {}
  local summary = empty_summary()

  for sorted_index, response in ipairs(sorted) do
    local items, is_empty = raw_items(response.result)
    if is_empty then
      summary.usable_response_count = summary.usable_response_count + 1
      summary.empty_response_count = summary.empty_response_count + 1
    else
      local valid_count = 0
      local invalid_count = 0
      for item_index, raw in ipairs(items) do
        local uri, range = protocol_location(raw)
        local item = self:_safe_item(response.client, raw, uri, range, nil, item_index, nil)
        if item then
          valid_count = valid_count + 1
          table.insert(presentation, item)
          add_unique(unique, seen, item.location)
        else
          invalid_count = invalid_count + 1
        end
      end
      if valid_count > 0 then
        summary.usable_response_count = summary.usable_response_count + 1
      else
        summary.invalid_response_count = summary.invalid_response_count + 1
      end
      if invalid_count > 0 then
        table.insert(failures, failure(response.client, sorted_index, invalid_count))
      end
    end
  end

  return presentation, unique, failures, summary
end

function Normalize:call_sites(direction, client, prepared_item, calls)
  assert(direction == "incoming" or direction == "outgoing", "unknown call hierarchy direction")
  local presentation = {}
  local unique = {}
  local seen = {}
  local failures = {}
  local summary = empty_summary()

  if calls == nil or (type(calls) == "table" and next(calls) == nil) then
    summary.usable_response_count = 1
    summary.empty_response_count = 1
    return presentation, unique, failures, summary
  end

  local total_valid = 0
  local total_invalid = 0
  for call_index, call in ipairs(type(calls) == "table" and calls or { calls }) do
    local ranges = type(call) == "table" and call.fromRanges or nil
    local owner
    if type(call) == "table" then
      owner = direction == "incoming" and call.from or call.to
    end
    local uri
    if direction == "incoming" then
      uri = type(owner) == "table" and owner.uri or nil
    else
      uri = type(prepared_item) == "table" and type(prepared_item.item) == "table" and prepared_item.item.uri or nil
    end
    local preferred_symbol = type(owner) == "table" and owner.name or nil
    local valid_count = 0
    local invalid_count = 0
    local project_owner
    if type(owner) == "table" then
      project_owner = self:is_project_uri(owner.uri)
    end

    if project_owner == false then
      -- An outgoing row is displayed at its origin call site, so project
      -- membership must follow the semantic caller/callee item instead.
    elseif type(ranges) ~= "table" or #ranges == 0 then
      invalid_count = 1
    elseif project_owner ~= true then
      invalid_count = #ranges
    else
      local query_anchor = self:_safe_query_anchor(client, owner)
      if not query_anchor then
        invalid_count = #ranges
      else
        for range_index, range in ipairs(ranges) do
          local item = self:_safe_item(client, call, uri, range, preferred_symbol, call_index, range_index)
          if item then
            item.location.query_anchor = vim.deepcopy(query_anchor)
            item.location.symbol_kind = Symbols.kind_name(owner.kind)
            item.location.identity = Locator.location_key(item.location)
            item.identity = item.location.identity
            valid_count = valid_count + 1
            table.insert(presentation, item)
            add_unique(unique, seen, item.location)
          else
            invalid_count = invalid_count + 1
          end
        end
      end
    end

    total_valid = total_valid + valid_count
    total_invalid = total_invalid + invalid_count
  end

  if total_valid > 0 then
    summary.usable_response_count = 1
  elseif total_invalid == 0 then
    summary.usable_response_count = 1
    summary.empty_response_count = 1
  else
    summary.invalid_response_count = 1
  end
  if total_invalid > 0 then
    table.insert(failures, failure(client, 1, total_invalid))
  end

  return presentation, unique, failures, summary
end

return M
