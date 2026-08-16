local Config = require("voyager.config")
local Runtime = require("voyager.runtime")
local Session = require("voyager.session")

local configured = Config.resolve({})
local active_session
local M = {}

local recursive_directions = { callers = true, callees = true }
local recursive_options = {
  { "depth", 1, 10 },
  { "max_subjects", 1, 1000 },
  { "concurrency", 1, 16 },
}
local recursive_option_keys = {
  direction = true,
  depth = true,
  max_subjects = true,
  concurrency = true,
  origin_id = true,
}

local function build_option_error(opts)
  if opts ~= nil and type(opts) ~= "table" then
    return "options must be a table"
  end
  opts = opts or {}
  for key in pairs(opts) do
    if not recursive_option_keys[key] then
      return tostring(key) .. " is not a supported option"
    end
  end
  if opts.origin_id ~= nil and (type(opts.origin_id) ~= "string" or opts.origin_id == "") then
    return "origin_id must be a non-empty string"
  end
  if opts.direction ~= nil and not recursive_directions[opts.direction] then
    return "direction must be 'callers' or 'callees'"
  end
  for _, option in ipairs(recursive_options) do
    local name, minimum, maximum = option[1], option[2], option[3]
    local value = opts[name]
    if value ~= nil and (type(value) ~= "number" or value % 1 ~= 0 or value < minimum or value > maximum) then
      return string.format("%s must be an integer from %d through %d", name, minimum, maximum)
    end
  end
end

function M.setup(opts)
  configured = Config.resolve(opts)
end

local function session()
  if not active_session then
    active_session = Session.native(function()
      return vim.deepcopy(configured)
    end, Runtime.native())
  end
  return active_session
end

function M.open()
  return session():open()
end

function M.focus()
  return session():focus()
end

function M.save()
  return session():save()
end

function M.load()
  return session():load()
end

function M.close()
  return session():close("command")
end

function M.toggle()
  local controller = session()
  if controller:is_active() then
    return controller:close("command")
  end
  return controller:open()
end

function M.export()
  return session():export()
end

function M.build(opts)
  local option_error = build_option_error(opts)
  if option_error then
    vim.notify("Voyager: recursive " .. option_error, vim.log.levels.ERROR)
    return nil
  end
  local controller = session()
  if not controller:is_active() and not controller:open() then
    return nil
  end
  return controller:build(opts)
end

function M.cancel_build()
  if not active_session or not active_session:is_active() then
    return nil
  end
  return active_session:cancel_build()
end

function M.status()
  if not active_session or not active_session:is_active() then
    return nil
  end
  local state = active_session:state()
  if not state.flow then
    return {
      name = "(waiting)",
      dirty = false,
      locations = 0,
      requests = state.request_count,
    }
  end
  local locations = 0
  for _, node in ipairs(state.flow:dfs()) do
    if node.kind == "location" then
      locations = locations + 1
    end
  end
  return {
    name = state.flow.name,
    dirty = state.flow:is_dirty(),
    locations = locations,
    requests = state.request_count,
    recursive = state.recursive and {
      direction = state.recursive.direction,
      state = state.recursive.state,
    } or nil,
  }
end

function M._session_for_tests()
  return active_session
end

function M._reset_for_tests()
  if active_session then
    active_session:shutdown()
  end
  active_session = nil
  configured = Config.resolve({})
end

return M
