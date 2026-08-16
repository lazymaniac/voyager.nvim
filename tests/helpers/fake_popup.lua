local M = {}

function M.new()
  local fake = {
    factory_calls = {},
    focus_count = 0,
    hide_count = 0,
    map_calls = {},
    mount_count = 0,
    show_count = 0,
    unmount_count = 0,
    update_layout_calls = {},
    center_calls = {},
    _next_winid = 9000,
  }

  local function open_window(popup)
    fake._next_winid = fake._next_winid + 1
    fake.winid = fake._next_winid
    popup.winid = fake.winid
    popup.mounted = true
    fake.focused = false
  end

  fake.factory = function(options)
    table.insert(fake.factory_calls, vim.deepcopy(options))

    local popup = {
      bufnr = vim.api.nvim_create_buf(false, true),
      cursor = { 1, 0 },
      mappings = {},
      mounted = false,
      options = vim.deepcopy(options),
    }
    fake.popup = popup
    fake.bufnr = popup.bufnr

    function popup:mount()
      fake.mount_count = fake.mount_count + 1
      open_window(self)
    end

    function popup:hide()
      fake.hide_count = fake.hide_count + 1
      if self.winid == nil then
        return
      end
      self.winid = nil
      self.mounted = false
      fake.winid = nil
      fake.focused = false
      if self._winclosed then
        self._winclosed()
      end
    end

    function popup:show()
      fake.show_count = fake.show_count + 1
      open_window(self)
    end

    function popup:unmount()
      fake.unmount_count = fake.unmount_count + 1
      self:hide()
      if vim.api.nvim_buf_is_valid(self.bufnr) then
        vim.api.nvim_buf_delete(self.bufnr, { force = true })
      end
    end

    function popup:update_layout(layout)
      table.insert(fake.update_layout_calls, vim.deepcopy(layout))
      self.options = vim.tbl_deep_extend("force", self.options, vim.deepcopy(layout))
    end

    function popup:map(mode, lhs, callback, options)
      self.mappings[lhs] = callback
      table.insert(fake.map_calls, {
        mode = mode,
        lhs = lhs,
        options = vim.deepcopy(options),
      })
    end

    function popup:on_win_closed(callback)
      self._winclosed = callback
    end

    function popup:get_cursor()
      return vim.deepcopy(self.cursor)
    end

    function popup:set_cursor(cursor)
      self.cursor = vim.deepcopy(cursor)
    end

    function popup:center_line(line, line_count)
      if self.winid == nil then
        return false
      end
      table.insert(fake.center_calls, { line = line, line_count = line_count })
      self.cursor = { line, 0 }
      return true
    end

    function popup:focus()
      fake.focus_count = fake.focus_count + 1
      fake.focused = true
    end

    function popup:is_focused()
      return fake.focused == true
    end

    fake.press = function(lhs)
      assert(popup.mappings[lhs], "fake popup mapping not found: " .. lhs)()
    end

    fake.set_cursor_line = function(line)
      popup.cursor = { line, 0 }
      fake.focused = true
    end

    fake.blur = function()
      fake.focused = false
    end

    fake.external_close = function()
      if popup.winid == nil then
        return
      end
      popup.winid = nil
      popup.mounted = false
      fake.winid = nil
      if popup._winclosed then
        popup._winclosed()
      end
    end

    return popup
  end

  return fake
end

return M
