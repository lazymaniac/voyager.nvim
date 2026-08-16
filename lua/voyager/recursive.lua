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

local function validate_targets(target_ids)
  assert(type(target_ids) == "table", "recursive target IDs must be a list")
  local count = 0
  for index, target_id in pairs(target_ids) do
    assert(type(index) == "number" and index % 1 == 0 and index > 0, "recursive target IDs must be a list")
    assert(type(target_id) == "string" and target_id ~= "", "recursive target ID must be a non-empty string")
    count = count + 1
  end
  assert(count == #target_ids, "recursive target IDs must be a dense list")
end

function M.new(opts)
  assert(type(opts) == "table", "recursive scheduler options are required")
  local seed_id = nonempty_string(opts.seed_id, "recursive seed ID")
  local self = setmetatable({
    action_name = nonempty_string(opts.action_name, "recursive action name"),
    max_depth = positive_integer(opts.max_depth, "recursive max depth"),
    max_subjects = positive_integer(opts.max_subjects, "recursive max subjects"),
    concurrency = positive_integer(opts.concurrency, "recursive concurrency"),
    _active = 0,
    _active_by_depth = {},
    _allowance = opts.max_subjects,
    _cancelled = false,
    _claims = {},
    _depth = 0,
    _issues = 0,
    _processed = 0,
    _queue = { { subject_id = seed_id, depth = 0 } },
    _queue_head = 1,
    _scheduled = 1,
    _seen = { [seed_id] = true },
  }, Recursive)
  return self
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

function Recursive:is_paused()
  return not self._cancelled and not self:_queue_empty() and self._processed + self._active >= self._allowance
end

function Recursive:claim()
  if self._cancelled or self:_queue_empty() or self._active >= self.concurrency or self:is_paused() then
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
    action_name = self.action_name,
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
  validate_targets(target_ids)

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
    self._depth = math.max(self._depth, math.min(next_depth, self.max_depth))
  end
  if next_depth < self.max_depth then
    for _, target_id in ipairs(target_ids) do
      if not self._seen[target_id] then
        self._seen[target_id] = true
        table.insert(self._queue, { subject_id = target_id, depth = next_depth })
        self._scheduled = self._scheduled + 1
      end
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

function Recursive:resume()
  if self._cancelled then
    return false
  end
  self._allowance = self._allowance + self.max_subjects
  return true
end

function Recursive:status()
  local paused = self:is_paused()
  return {
    processed = self._processed,
    scheduled = self._scheduled,
    active = self._active,
    depth = self._depth,
    max_depth = self.max_depth,
    max_subjects = self.max_subjects,
    allowance = self._allowance,
    truncated = paused,
    paused = paused,
    cancelled = self._cancelled,
    issues = self._issues,
  }
end

return M
