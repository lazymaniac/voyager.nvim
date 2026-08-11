local M = {}
local Registry = {}
Registry.__index = Registry

local function normalized(lhs)
  return vim.keycode(lhs)
end

local function local_map(bufnr, normalized_lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    local lhs_ok, lhs = pcall(normalized, map.lhs)
    if (lhs_ok and lhs == normalized_lhs) or map.lhsraw == normalized_lhs or map.lhsrawalt == normalized_lhs then
      return map
    end
  end
end

local function global_map(normalized_lhs)
  for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
    local lhs_ok, lhs = pcall(normalized, map.lhs)
    if (lhs_ok and lhs == normalized_lhs) or map.lhsraw == normalized_lhs or map.lhsrawalt == normalized_lhs then
      return map
    end
  end
end

local function restore_map(bufnr, map)
  local rhs = map.callback or map.rhs
  vim.keymap.set("n", map.lhs, rhs, {
    buffer = bufnr,
    desc = map.desc ~= "" and map.desc or nil,
    expr = map.expr == 1,
    remap = map.noremap == 0,
    silent = map.silent == 1,
    nowait = map.nowait == 1,
    script = map.script == 1,
    replace_keycodes = map.replace_keycodes == 1,
  })
end

local function feed(keys, map)
  if type(keys) ~= "string" or keys == "" then
    return
  end
  local literal = map.expr == 1 and map.replace_keycodes ~= 1
  if not literal then
    keys = vim.keycode(keys)
  end
  vim.api.nvim_feedkeys(keys, map.noremap == 1 and "n" or "m", literal)
end

local function invoke_map(map)
  if map.callback then
    local ok, result = pcall(map.callback)
    if not ok then
      return false, result
    end
    if map.expr == 1 then
      feed(result, map)
    end
    return true
  end
  local rhs = map.rhs
  if type(rhs) ~= "string" or rhs == "" then
    return false, "mapping has no callback or right-hand side"
  end
  if map.expr == 1 then
    local ok, evaluated = pcall(vim.api.nvim_eval, rhs)
    if not ok then
      return false, evaluated
    end
    feed(evaluated, map)
    return true
  end
  feed(rhs, map)
  return true
end

local function record_key(generation, bufnr, normalized_lhs)
  return table.concat({ tostring(generation), tostring(bufnr), "n", normalized_lhs }, "\0")
end

function M.new(opts)
  opts = opts or {}
  assert(type(opts.notify) == "function", "Voyager keymap notification adapter is required")
  return setmetatable({
    _notify = opts.notify,
    _records = {},
  }, Registry)
end

function Registry:_delegate(record)
  local previous = record.original or global_map(record.normalized_lhs)
  if not previous then
    return false
  end
  local invoked, invoke_error = invoke_map(previous)
  if not invoked then
    self._notify(
      "Voyager: previous mapping for " .. record.installed_lhs .. " failed: " .. tostring(invoke_error),
      vim.log.levels.ERROR
    )
  end
  return true
end

function Registry:apply_buffer(bufnr, generation, mappings, wrapper_factory)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  for action_name, lhs in pairs(mappings) do
    if lhs ~= false then
      local normalized_lhs = normalized(lhs)
      local key = record_key(generation, bufnr, normalized_lhs)
      if not self._records[key] then
        local original = local_map(bufnr, normalized_lhs)
        local effective = original or global_map(normalized_lhs)
        local record = {
          generation = generation,
          bufnr = bufnr,
          normalized_lhs = normalized_lhs,
          installed_lhs = lhs,
          original = original,
          restored = false,
        }
        local wrapper = wrapper_factory(action_name, function()
          return self:_delegate(record)
        end)
        vim.keymap.set("n", lhs, wrapper, {
          buffer = bufnr,
          desc = "Voyager: " .. action_name,
          silent = true,
          nowait = effective ~= nil and effective.nowait == 1,
        })
        record.wrapper = wrapper
        self._records[key] = record
      end
    end
  end
end

function Registry:is_installed(bufnr, lhs)
  local normalized_lhs = normalized(lhs)
  for _, record in pairs(self._records) do
    if record.bufnr == bufnr and record.normalized_lhs == normalized_lhs and not record.restored then
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
      end
      local current = local_map(bufnr, normalized_lhs)
      return current ~= nil and current.callback == record.wrapper
    end
  end
  return false
end

function Registry:restore_all(generation)
  for _, record in pairs(self._records) do
    if record.generation == generation and not record.restored then
      record.restored = true
      if vim.api.nvim_buf_is_valid(record.bufnr) then
        local current = local_map(record.bufnr, record.normalized_lhs)
        if current and current.callback == record.wrapper then
          vim.keymap.del("n", record.installed_lhs, { buffer = record.bufnr })
          if record.original then
            restore_map(record.bufnr, record.original)
          end
        else
          self._notify(
            "Voyager: mapping " .. record.installed_lhs .. " changed ownership; leaving the newer mapping intact"
          )
        end
      end
    end
  end
end

return M
