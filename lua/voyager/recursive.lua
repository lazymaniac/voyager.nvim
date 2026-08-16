local M = {}
local Recursive = {}
Recursive.__index = Recursive

local function positive_integer(value, name)
  assert(type(value) == "number" and value % 1 == 0 and value > 0, name .. " must be a positive integer")
  return value
end

local function nonempty_string(value, name)
  assert(type(value) == "string" and value ~= "", name .. " must be a non-empty string")
  return value
end

local function validate_list(values, name, allow_empty)
  assert(type(values) == "table", name .. " must be a list")
  local count = 0
  for index, value in pairs(values) do
    assert(type(index) == "number" and index % 1 == 0 and index > 0, name .. " must be a list")
    assert(type(value) == "string" and value ~= "", name .. " item must be a non-empty string")
    count = count + 1
  end
  assert(count == #values and (allow_empty or count > 0), name .. " must be a dense list")
end

local function work_key(action_name, subject_id)
  return action_name .. "\0" .. subject_id
end

function M.new(opts)
  assert(type(opts) == "table", "recursive scheduler options are required")
  local seed_id = nonempty_string(opts.seed_id, "recursive seed ID")
  validate_list(opts.action_names, "recursive action names", false)

  local queue = {}
  local seen = {}
  for _, action_name in ipairs(opts.action_names) do
    nonempty_string(action_name, "recursive action name")
    local key = work_key(action_name, seed_id)
    assert(not seen[key], "recursive action names must be unique")
    seen[key] = true
    table.insert(queue, { subject_id = seed_id, action_name = action_name, depth = 0 })
  end

  return setmetatable({
    concurrency = positive_integer(opts.concurrency, "recursive concurrency"),
    _active = 0,
    _active_by_depth = {},
    _cancelled = false,
    _claims = {},
    _depth = 0,
    _issues = 0,
    _processed = 0,
    _queue = queue,
    _queue_head = 1,
    _scheduled = #queue,
    _seen = seen,
  }, Recursive)
end

function Recursive:_queue_empty()
  return self._queue_head > #self._queue
end

function Recursive:_minimum_active_depth()
  local minimum
  for depth, count in pairs(self._active_by_depth) do
    if count > 0 and (minimum == nil or depth < minimum) then
      minimum = depth
    end
  end
  return minimum
end

function Recursive:claim()
  if self._cancelled or self:_queue_empty() or self._active >= self.concurrency then
    return nil
  end

  local queued = self._queue[self._queue_head]
  local active_depth = self:_minimum_active_depth()
  if active_depth ~= nil and queued.depth > active_depth then
    return nil
  end

  self._queue_head = self._queue_head + 1
  local item = {
    subject_id = queued.subject_id,
    action_name = queued.action_name,
    depth = queued.depth,
  }
  self._claims[item] = queued
  self._active = self._active + 1
  self._active_by_depth[queued.depth] = (self._active_by_depth[queued.depth] or 0) + 1
  return item
end

function Recursive:complete(item, target_ids, issue)
  local claimed = type(item) == "table" and self._claims[item] or nil
  if self._cancelled or not claimed then
    return false
  end
  validate_list(target_ids, "recursive target IDs", true)

  self._claims[item] = nil
  self._active = self._active - 1
  local remaining_at_depth = assert(self._active_by_depth[claimed.depth]) - 1
  if remaining_at_depth == 0 then
    self._active_by_depth[claimed.depth] = nil
  else
    self._active_by_depth[claimed.depth] = remaining_at_depth
  end
  self._processed = self._processed + 1
  if issue then
    self._issues = self._issues + 1
  end

  local next_depth = claimed.depth + 1
  if #target_ids > 0 then
    self._depth = math.max(self._depth, next_depth)
  end
  for _, target_id in ipairs(target_ids) do
    local key = work_key(claimed.action_name, target_id)
    if not self._seen[key] then
      self._seen[key] = true
      table.insert(self._queue, {
        subject_id = target_id,
        action_name = claimed.action_name,
        depth = next_depth,
      })
      self._scheduled = self._scheduled + 1
    end
  end
  return true
end

function Recursive:cancel()
  if self._cancelled then
    return false
  end
  self._cancelled = true
  self._queue = {}
  self._queue_head = 1
  self._claims = {}
  self._active = 0
  self._active_by_depth = {}
  return true
end

function Recursive:is_done()
  return self._cancelled or (self._active == 0 and self:_queue_empty())
end

function Recursive:status()
  return {
    processed = self._processed,
    scheduled = self._scheduled,
    active = self._active,
    depth = self._depth,
    concurrency = self.concurrency,
    cancelled = self._cancelled,
    issues = self._issues,
  }
end

return M
