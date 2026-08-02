local Keymaps = require("voyager.keymaps")

describe("Voyager keymaps", function()
  it("restores a reconstructible local callback mapping", function()
    local buffer = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buffer)
    local original = function() end
    vim.keymap.set("n", "gd", original, {
      buffer = buffer,
      desc = "original",
      expr = false,
      silent = true,
      nowait = true,
      remap = false,
    })
    local registry = Keymaps.new({ notify = function() end })
    registry:apply_buffer(buffer, 9, { definition = "gd" }, function()
      return function() end
    end)
    registry:restore_all(9)
    local restored = vim.fn.maparg("gd", "n", false, true)
    assert.equals(original, restored.callback)
    assert.equals("original", restored.desc)
    assert.equals(1, restored.silent)
    assert.equals(1, restored.nowait)
    vim.api.nvim_buf_delete(buffer, { force = true })
  end)

  it("matches equivalent normalized lhs spellings", function()
    local buffer = vim.api.nvim_create_buf(true, false)
    local original = function()
      return "original"
    end
    vim.keymap.set("n", "<C-I>", original, { buffer = buffer, expr = true, replace_keycodes = false })
    local registry = Keymaps.new({ notify = function() end })
    registry:apply_buffer(buffer, 9, { definition = "<Tab>" }, function()
      return function() end
    end)
    assert.is_true(registry:is_installed(buffer, "<C-I>"))
    registry:restore_all(9)
    local restored = vim.api.nvim_buf_call(buffer, function()
      return vim.fn.maparg("<C-I>", "n", false, true)
    end)
    assert.equals(original, restored.callback)
    assert.equals(1, restored.expr)
    assert.equals(0, restored.replace_keycodes)
    vim.api.nvim_buf_delete(buffer, { force = true })
  end)

  it("restores an rhs and all reconstructible flags", function()
    local buffer = vim.api.nvim_create_buf(true, false)
    vim.keymap.set("n", "gd", "gD", {
      buffer = buffer,
      desc = "rhs original",
      expr = true,
      remap = true,
      script = true,
      silent = true,
      nowait = true,
      replace_keycodes = false,
    })
    local registry = Keymaps.new({ notify = function() end })
    registry:apply_buffer(buffer, 9, { definition = "gd" }, function()
      return function() end
    end)
    registry:restore_all(9)
    local restored = vim.api.nvim_buf_call(buffer, function()
      return vim.fn.maparg("gd", "n", false, true)
    end)
    assert.equals("gD", restored.rhs)
    assert.equals("rhs original", restored.desc)
    assert.equals(1, restored.expr)
    assert.equals(1, restored.script)
    assert.equals(1, restored.silent)
    assert.equals(1, restored.nowait)
    assert.equals(0, restored.replace_keycodes)
    vim.api.nvim_buf_delete(buffer, { force = true })
  end)

  it("reveals a global map and never overwrites a newer local owner", function()
    local warnings = {}
    local buffer = vim.api.nvim_create_buf(true, false)
    vim.keymap.set("n", "gd", "global", {})
    local registry = Keymaps.new({
      notify = function(message)
        table.insert(warnings, message)
      end,
    })
    registry:apply_buffer(buffer, 9, { definition = "gd" }, function()
      return function() end
    end)
    registry:restore_all(9)
    assert.equals("global", vim.fn.maparg("gd", "n"))

    registry = Keymaps.new({
      notify = function(message)
        table.insert(warnings, message)
      end,
    })
    registry:apply_buffer(buffer, 10, { definition = "gd" }, function()
      return function() end
    end)
    vim.keymap.set("n", "gd", "new owner", { buffer = buffer })
    registry:restore_all(10)
    registry:restore_all(10)
    assert.equals("new owner", vim.api.nvim_buf_call(buffer, function()
      return vim.fn.maparg("gd", "n")
    end))
    assert.equals(1, #warnings)
    vim.keymap.del("n", "gd")
    vim.api.nvim_buf_delete(buffer, { force = true })
  end)

  it("applies each enabled normalized mapping once and ignores wiped buffers", function()
    local calls = {}
    local registry = Keymaps.new({ notify = function() end })
    local live = vim.api.nvim_create_buf(true, false)
    local wiped = vim.api.nvim_create_buf(true, false)
    local config = { definition = "gd", references = "grr", declaration = false }
    local factory = function(action)
      calls[action] = (calls[action] or 0) + 1
      return function() end
    end

    registry:apply_buffer(live, 11, config, factory)
    registry:apply_buffer(live, 11, config, factory)
    registry:apply_buffer(wiped, 11, config, factory)
    vim.api.nvim_buf_delete(wiped, { force = true })
    assert.has_no.errors(function()
      registry:restore_all(11)
      registry:restore_all(11)
    end)

    assert.same({ definition = 2, references = 2 }, calls)
    assert.is_false(registry:is_installed(live, "gd"))
    vim.api.nvim_buf_delete(live, { force = true })
  end)
end)
