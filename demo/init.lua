-- Interactive Voyager demo against the bundled deterministic LSP fixture.
--
--   make deps                     (once, installs nui.nvim)
--   nvim -u demo/init.lua
--
-- The fixture server implements all seven navigation methods for the tiny
-- project in tests/fixtures/project, so no real language server is needed.
-- Optional environment overrides:
--   VOYAGER_DEMO_ICONS=text      plain-text markers instead of Nerd Font glyphs
--   VOYAGER_DEMO_PATH=shortened  sidebar.path style (relative|filename|shortened)
--   VOYAGER_DEMO_AUTOSAVE=1      enable storage.autosave

local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.normalize(vim.fs.dirname(vim.fs.dirname(vim.uv.fs_realpath(source) or source)))
local nui = root .. "/.deps/nui.nvim"
if not vim.uv.fs_stat(nui .. "/lua/nui/popup/init.lua") then
  error("demo requires nui.nvim; run `make deps` in " .. root)
end
vim.opt.runtimepath:prepend(nui)
vim.opt.runtimepath:prepend(root)

vim.o.termguicolors = true
vim.o.swapfile = false
vim.o.number = true
vim.o.signcolumn = "yes"

-- Copy the fixture project into a scratch directory so saved flows and edits
-- never touch the repository checkout.
local project = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.tempname(), ":h") .. "/voyager-demo-project")
vim.fn.delete(project, "rf")
vim.fn.mkdir(project, "p")
local function copy_tree(from, into)
  for name, kind in vim.fs.dir(from) do
    local source_path = from .. "/" .. name
    local target_path = into .. "/" .. name
    if kind == "directory" then
      vim.fn.mkdir(target_path, "p")
      copy_tree(source_path, target_path)
    else
      vim.fn.writefile(vim.fn.readfile(source_path, "b"), target_path, "b")
    end
  end
end
copy_tree(root .. "/tests/fixtures/project", project)

require("voyager").setup({
  sidebar = {
    icons = os.getenv("VOYAGER_DEMO_ICONS") ~= "text",
    path = os.getenv("VOYAGER_DEMO_PATH") or "relative",
  },
  storage = { autosave = os.getenv("VOYAGER_DEMO_AUTOSAVE") == "1" },
})

vim.g.mapleader = " "
vim.keymap.set("n", "<leader>vv", "<cmd>VoyagerToggle<cr>", { desc = "Voyager toggle" })
vim.keymap.set("n", "<leader>vf", "<cmd>VoyagerFocus<cr>", { desc = "Voyager focus" })
vim.keymap.set("n", "<leader>vl", "<cmd>VoyagerLoad<cr>", { desc = "Voyager load" })
vim.keymap.set("n", "<leader>ve", "<cmd>VoyagerExport<cr>", { desc = "Voyager export" })

-- Statusline integration demo for require("voyager").status().
function _G.VoyagerStatusline()
  local status = require("voyager").status()
  if not status then
    return ""
  end
  return string.format(" Voyager: %s%s · %d locations ", status.name, status.dirty and " *" or "", status.locations)
end
vim.o.laststatus = 3
vim.o.statusline = "%f %m%=%{v:lua.VoyagerStatusline()} %l:%c "

-- Start both fixture clients (UTF-8 and UTF-16) exactly like the e2e harness.
local server = root .. "/tests/fixtures/lsp/server.lua"
local client_ids = {}
for _, encoding in ipairs({ "utf-8", "utf-16" }) do
  local client_id = vim.lsp.start({
    name = "voyager-fixture-" .. encoding:gsub("-", ""),
    cmd = { vim.v.progpath, "--clean", "--headless", "-l", server, encoding, project },
    root_dir = project,
  }, { attach = false })
  if client_id then
    table.insert(client_ids, client_id)
  end
end
vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
  group = vim.api.nvim_create_augroup("VoyagerDemoAttach", { clear = true }),
  callback = function(event)
    local name = vim.fs.normalize(vim.api.nvim_buf_get_name(event.buf))
    if name:sub(1, #project + 1) ~= project .. "/" then
      return
    end
    for _, client_id in ipairs(client_ids) do
      vim.lsp.buf_attach_client(event.buf, client_id)
    end
  end,
})

vim.cmd.edit(vim.fn.fnameescape(project .. "/lua/main.lua"))
for row, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
  local col = line:find("main", 1, true)
  if col then
    vim.api.nvim_win_set_cursor(0, { row, col - 1 })
    break
  end
end

vim.defer_fn(function()
  vim.notify("Voyager demo ready: <Space>vv opens the flow, gri/grr/gd navigate, see demo/TOUR.md", vim.log.levels.INFO)
end, 200)
