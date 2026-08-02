local M = {}

function M.new()
  local timers = { created = {} }

  timers.factory = function(timeout_ms, callback)
    local timer = {
      timeout_ms = timeout_ms,
      callback = callback,
      cancel_count = 0,
      close_count = 0,
      fired = false,
    }
    table.insert(timers.created, timer)
    timers.last = timer

    function timer:cancel()
      self.cancel_count = self.cancel_count + 1
    end

    function timer:close()
      self.close_count = self.close_count + 1
    end

    function timer:fire()
      if not self.fired then
        self.fired = true
        self.callback()
      end
    end

    return timer
  end

  function timers:fire()
    assert(self.last, "no fake timer exists"):fire()
  end

  return timers
end

return M
