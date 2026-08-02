dofile(vim.fn.getcwd() .. "/tests/minimal_init.lua")

-- Locator targets are loaded into hidden buffers. Neovim's Lua ftplugin starts
-- Tree-sitter during BufReadPost, before those buffers are ready for a parser.
-- The journey tests exercise Voyager and LSP behavior, not filetype plugins.
vim.cmd("filetype plugin off")
vim.lsp.log.set_level("debug")
vim.cmd("runtime plugin/voyager.lua")

local fixture_root = assert(os.getenv("VOYAGER_E2E_ROOT"), "VOYAGER_E2E_ROOT is required")
fixture_root = vim.fs.normalize(fixture_root)
local server_path = vim.fn.getcwd() .. "/tests/fixtures/lsp/server.lua"

local E2E = { root = fixture_root, client_ids = {} }
_G.VoyagerE2E = E2E

local function log_tail()
  local path = vim.lsp.log.get_filename()
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return "unable to read LSP log " .. path .. ": " .. tostring(lines)
  end
  local tail = {}
  for index = math.max(1, #lines - 120), #lines do
    table.insert(tail, lines[index])
  end
  return table.concat(tail, "\n")
end

function E2E.wait(label, predicate)
  assert(vim.wait(5000, predicate, 10, false), label .. " timed out after 5000ms\nLSP log:\n" .. log_tail())
end

function E2E.wait_for_clients(bufnr)
  local attached = {}
  local ready = vim.wait(5000, function()
    local seen = {}
    attached = {}
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
      seen[client.name] = true
      table.insert(attached, client.name)
    end
    return seen["voyager-fixture-utf8"] and seen["voyager-fixture-utf16"]
  end, 10, false)
  assert(ready, vim.inspect({
    message = "two fixture clients did not attach",
    bufnr = bufnr,
    name = vim.api.nvim_buf_get_name(bufnr),
    current_buf = vim.api.nvim_get_current_buf(),
    attached = attached,
  }) .. "\nLSP log:\n" .. log_tail())
end

function E2E.wait_for_requests(session)
  E2E.wait("Voyager requests settling", function()
    return session:state().request_count == 0
  end)
end

function E2E.action(location, method)
  for _, action in ipairs(location.actions) do
    if action.method == method then
      return action
    end
  end
end

function E2E.result(action, suffix)
  for _, result in ipairs(action.results) do
    local locator = result.location.locator
    local value = locator.path or locator.uri
    if value:sub(-#suffix) == suffix then
      return result
    end
  end
end

function E2E.place_cursor(bufnr, needle)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local column = line:find(needle, 1, true)
    if column then
      vim.api.nvim_win_set_cursor(0, { row, column - 1 })
      return
    end
  end
  error("fixture needle not found: " .. needle)
end

vim.cmd.edit(vim.fn.fnameescape(fixture_root .. "/lua/main.lua"))
E2E.source_buf = vim.api.nvim_get_current_buf()
E2E.source_win = vim.api.nvim_get_current_win()
E2E.place_cursor(E2E.source_buf, "main")

for _, encoding in ipairs({ "utf-8", "utf-16" }) do
  local client_id = assert(
    vim.lsp.start({
      name = "voyager-fixture-" .. encoding:gsub("-", ""),
      cmd = { vim.v.progpath, "--clean", "--headless", "-l", server_path, encoding, fixture_root },
      root_dir = fixture_root,
    }, { bufnr = E2E.source_buf }),
    "failed to start " .. encoding .. " fixture client"
  )
  table.insert(E2E.client_ids, client_id)
end

local attach_group = vim.api.nvim_create_augroup("VoyagerE2EAttach", { clear = true })
vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
  group = attach_group,
  callback = function(event)
    local name = vim.fs.normalize(vim.api.nvim_buf_get_name(event.buf))
    local prefix = fixture_root .. "/"
    if name:sub(1, #prefix) ~= prefix then
      return
    end
    for _, client_id in ipairs(E2E.client_ids) do
      vim.lsp.buf_attach_client(event.buf, client_id)
    end
  end,
})

E2E.wait_for_clients(E2E.source_buf)
