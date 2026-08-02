local Config = require("voyager.config")
local Runtime = require("voyager.runtime")
local Session = require("voyager.session")

local configured = Config.resolve({})
local active_session
local M = {}

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
