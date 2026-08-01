# Voyager Navigation Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the prototype's linear two-pane navigator with a tested, persistent branching LSP exploration tree shown in a small session-owned sidebar.

**Architecture:** A process-wide `session.lua` coordinates focused modules for validated configuration, canonical locations, the pure flow tree, storage, session-owned mappings, LSP transport/normalization/presentation, and a NUI sidebar. All asynchronous boundaries use generation and interaction tokens; persistence is synchronous and atomic; the public `require("voyager").setup()` entry point remains stable.

**Tech Stack:** Neovim 0.12.4 Lua API, LuaJIT/Lua 5.1, `nui.nvim` 0.4.0, Plenary Busted, StyleLua 2.5.2, JSON schema v1, GitHub Actions, LuaRocks 3.13.0.

---

## Working rules

- Run every command from `/Users/sebastian/workspace/voyager.nvim/.worktrees/voyager-navigation-flow`.
- Read `docs/superpowers/specs/2026-08-01-voyager-navigation-flow-design.md` before Task 1 and keep it open while implementing.
- Follow red-green-refactor: add one focused failing example, run that exact file, implement only the behavior under test, rerun it, then run `make test-unit` before committing.
- Use only IDs across asynchronous callbacks; never retain mutable flow-node tables.
- Do not use `vim.lsp.buf_request_all`, do not patch `vim.lsp.buf.*`, and do not mount a user buffer in Voyager UI.
- Keep `.DS_Store` untracked and out of every commit.
- The known baseline failure is expected: `make test` cannot load Plenary because the current test init performs an unchecked network clone. Task 1 fixes it.

## Final file map

| File | Responsibility |
| --- | --- |
| `lua/voyager.lua` | Public configuration façade and singleton session access |
| `lua/voyager/config.lua` | Defaults, deep merge, strict validation, immutable snapshots |
| `lua/voyager/runtime.lua` | Injectable clock, entropy, synchronous filesystem, buffer, timer, input/select, and notification adapters |
| `lua/voyager/locator.lua` | Locator/range normalization, source resolution, root/name/hash/ID identity |
| `lua/voyager/flow.lua` | Pure alternating tree, mutation journal, navigation commits, recursive merge |
| `lua/voyager/schema.lua` | Strict schema-v1 validation and canonical JSON encoding |
| `lua/voyager/store.lua` | Project discovery, sync atomic I/O, latest-document merge, saved-flow listing |
| `lua/voyager/keymaps.lua` | Owned buffer-local mapping snapshots, wrappers, and restoration |
| `lua/voyager/sidebar.lua` | Pure row projection plus one NUI popup and sidebar-local mappings |
| `lua/voyager/lsp/actions.lua` | Immutable seven-action registry |
| `lua/voyager/lsp/normalize.lua` | Location, LocationLink, and call-site normalization |
| `lua/voyager/lsp/request_group.lua` | Per-client request slots, dispatch barrier, deadline, cancellation |
| `lua/voyager/lsp/call_hierarchy.lua` | Prepare/pick/same-client follow-up state machine |
| `lua/voyager/lsp/presentation.lua` | Native jump/list behavior, item tags, custom `on_list` token |
| `lua/voyager/lsp.lua` | LSP façade returning exactly-once normalized outcomes |
| `lua/voyager/session.lua` | Only lifecycle owner; flow/UI/LSP/store orchestration |
| `plugin/voyager.lua` | Five user commands |

The prototype files `locations_stack.lua`, `lsp_client.lua`, `spinner.lua`, `ui.lua`, and all three `lua/voyager/utils/*.lua` files are removed only after the replacement façade is green in Task 17.

### Task 1: Deterministic dependency and test harness

**Files:**
- Modify: `.gitignore`
- Modify: `Makefile`
- Create: `scripts/ensure-dependency`
- Replace: `tests/minimal_init.lua`
- Delete: `tests/voyager/plugin_name_spec.lua`
- Create: `tests/unit/harness_spec.lua`

- [ ] **Step 1: Replace the template assertion with a real smoke test**

Create `tests/unit/harness_spec.lua`:

```lua
describe("Voyager test runtime", function()
  it("loads Voyager and its pinned NUI dependency", function()
    assert.is_table(require("voyager"))
    assert.is_table(require("nui.popup"))
  end)
end)
```

Delete `tests/voyager/plugin_name_spec.lua`; it calls a nonexistent `hello()` template API.

- [ ] **Step 2: Run the smoke test and preserve the known red result**

Run: `make test-unit`

Expected: FAIL before the Makefile rewrite because `test-unit` does not exist, or because `plenary.busted` cannot be loaded. Do not let Neovim remain running after the failure.

- [ ] **Step 3: Add the pinned dependency installer**

Create executable `scripts/ensure-dependency`:

```sh
#!/bin/sh
set -eu

mode=$1
name=$2
url=$3
revision=$4
target=$5

current_revision() {
  git -C "$target" rev-parse HEAD 2>/dev/null || true
}

dependency_is_clean() {
  test -z "$(git -C "$target" status --porcelain=v1 --untracked-files=all 2>/dev/null || true)"
}

dependency_is_exact() {
  test -d "$target/.git" &&
    test "$(git -C "$target" remote get-url origin 2>/dev/null || true)" = "$url" &&
    test "$(current_revision)" = "$revision" &&
    dependency_is_clean
}

if [ "$mode" = "check" ]; then
  if ! dependency_is_exact; then
    echo "$name is missing, dirty, from the wrong origin, or not pinned to $revision; run 'make deps'" >&2
    exit 1
  fi
  exit 0
fi

if [ "$mode" != "install" ]; then
  echo "usage: ensure-dependency install|check NAME URL REVISION TARGET" >&2
  exit 2
fi

repo_root=$(git rev-parse --show-toplevel)
case "$target" in
  "$repo_root"/.deps/*) ;;
  *)
    echo "refusing to modify dependency outside $repo_root/.deps: $target" >&2
    exit 2
    ;;
esac

if [ ! -d "$target/.git" ]; then
  if [ -e "$target" ]; then
    echo "$target exists but is not a dependency checkout; remove it manually" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$target")"
  git clone --filter=blob:none --no-checkout "$url" "$target"
fi

if [ "$(git -C "$target" remote get-url origin 2>/dev/null || true)" != "$url" ]; then
  echo "$name has an unexpected origin; remove $target manually" >&2
  exit 1
fi

git -C "$target" fetch --depth=1 origin "$revision"
git -C "$target" checkout --detach --force "$revision"
git -C "$target" clean -ffdx
dependency_is_exact
```

Run: `chmod +x scripts/ensure-dependency`

- [ ] **Step 4: Make every test command network-free**

Replace `Makefile` with:

```make
NVIM ?= nvim
STYLUA ?= stylua
ROOT := $(abspath .)
DEPS := $(ROOT)/.deps
PLENARY := $(DEPS)/plenary.nvim
NUI := $(DEPS)/nui.nvim
PLENARY_REV := 50012918b2fc8357b87cff2a7f7f0446e47da174
NUI_REV := f535005e6ad1016383f24e39559833759453564e
STYLUA_VERSION := 2.5.2
TEST_ENV := env VOYAGER_TEST_ROOT=$(ROOT) NVIM_APPNAME=voyager-test XDG_CONFIG_HOME=$(ROOT)/.tmp/test/config XDG_CACHE_HOME=$(ROOT)/.tmp/test/cache XDG_STATE_HOME=$(ROOT)/.tmp/test/state XDG_DATA_HOME=$(ROOT)/.tmp/test/data
TEST_NVIM := $(TEST_ENV) $(NVIM) --headless --noplugin -i NONE -u tests/minimal_init.lua

ifeq ($(strip $(TEST_FILE)),)
UNIT_COMMAND := PlenaryBustedDirectory tests/unit { minimal_init = 'tests/minimal_init.lua' }
else
UNIT_COMMAND := PlenaryBustedFile $(TEST_FILE)
endif

.PHONY: deps check-deps check-stylua test test-unit format format-check

deps:
	@scripts/ensure-dependency install plenary.nvim https://github.com/nvim-lua/plenary.nvim.git $(PLENARY_REV) $(PLENARY)
	@scripts/ensure-dependency install nui.nvim https://github.com/MunifTanjim/nui.nvim.git $(NUI_REV) $(NUI)

check-deps:
	@scripts/ensure-dependency check plenary.nvim https://github.com/nvim-lua/plenary.nvim.git $(PLENARY_REV) $(PLENARY)
	@scripts/ensure-dependency check nui.nvim https://github.com/MunifTanjim/nui.nvim.git $(NUI_REV) $(NUI)

test: test-unit

test-unit: check-deps
	@$(TEST_NVIM) -c "$(UNIT_COMMAND)"

check-stylua:
	@command -v $(STYLUA) >/dev/null 2>&1 || { echo "StyleLua $(STYLUA_VERSION) is required" >&2; exit 1; }
	@actual="$$($(STYLUA) --version)"; test "$$actual" = "stylua $(STYLUA_VERSION)" || { echo "expected stylua $(STYLUA_VERSION), got $$actual" >&2; exit 1; }

format: check-stylua
	@$(STYLUA) lua plugin tests

format-check: check-stylua
	@$(STYLUA) --check lua plugin tests
```

Append these exact ignore rules to `.gitignore`:

```gitignore
.deps/
.tmp/
nvim.log
```

Replace `tests/minimal_init.lua` with:

```lua
local root = vim.fn.getcwd()

assert(vim.env.VOYAGER_TEST_ROOT == root, "tests must run through make test-unit")
vim.opt.runtimepath = table.concat({
  root,
  root .. "/.deps/plenary.nvim",
  root .. "/.deps/nui.nvim",
  vim.env.VIMRUNTIME,
}, ",")
vim.opt.packpath = ""
vim.opt.loadplugins = false
vim.opt.shadafile = "NONE"
vim.opt.swapfile = false

vim.cmd("runtime plugin/plenary.vim")
require("plenary.busted")
```

- [ ] **Step 5: Install once, then prove tests do not fetch**

Run: `make deps`

Expected: `.deps/plenary.nvim` is at `50012918b2fc8357b87cff2a7f7f0446e47da174` and `.deps/nui.nvim` is at `f535005e6ad1016383f24e39559833759453564e`.

Run: `make test-unit`

Expected: PASS, 1 success, and no `git clone` or `git fetch` output.

Run: `printf 'dirty\n' > .deps/nui.nvim/voyager-dirty-check && ! make check-deps`

Expected: PASS because `check-deps` rejects the dirty checkout without fetching.

Run: `make deps && make check-deps`

Expected: PASS because `make deps` restores the exact clean pinned checkout. Task 18 is the only task that adds `test-e2e` and changes `test` to depend on both suites; until then `make test` is exactly the unit suite and never reports a nonexistent E2E suite as passing.

- [ ] **Step 6: Commit the harness**

```bash
git add .gitignore Makefile scripts/ensure-dependency tests/minimal_init.lua tests/unit/harness_spec.lua tests/voyager/plugin_name_spec.lua
git commit -m "test: make harness deterministic"
```

### Task 2: LSP action registry and validated configuration

**Files:**
- Create: `lua/voyager/lsp/actions.lua`
- Create: `lua/voyager/config.lua`
- Create: `tests/unit/actions_spec.lua`
- Create: `tests/unit/config_spec.lua`

- [ ] **Step 1: Specify all seven action records**

Create `tests/unit/actions_spec.lua`:

```lua
local Actions = require("voyager.lsp.actions")

describe("Voyager LSP actions", function()
  it("defines the native methods and presentation policies in stable order", function()
    assert.same({
      "definition",
      "declaration",
      "references",
      "implementation",
      "type_definition",
      "incoming_calls",
      "outgoing_calls",
    }, Actions.names())
    assert.same("textDocument/declaration", Actions.get("declaration").method)
    assert.same("always_list", Actions.get("references").presentation)
    assert.same({ includeDeclaration = true }, Actions.get("references").context)
    assert.same("incoming", Actions.get("incoming_calls").direction)
    assert.same("outgoing", Actions.get("outgoing_calls").direction)
    local internal_name, internal = Actions.by_method("voyager/manual")
    assert.equals("manual", internal_name)
    assert.equals("manual jump", internal.label)
  end)
end)
```

- [ ] **Step 2: Verify the registry test is red**

Run: `make test-unit TEST_FILE=tests/unit/actions_spec.lua`

Expected: FAIL with `module 'voyager.lsp.actions' not found`.

- [ ] **Step 3: Implement the immutable registry**

Create `lua/voyager/lsp/actions.lua`:

```lua
local order = {
  "definition",
  "declaration",
  "references",
  "implementation",
  "type_definition",
  "incoming_calls",
  "outgoing_calls",
}

local records = {
  definition = { method = "textDocument/definition", label = "definition", presentation = "jump_or_list" },
  declaration = { method = "textDocument/declaration", label = "declaration", presentation = "jump_or_list" },
  references = {
    method = "textDocument/references",
    label = "references",
    presentation = "always_list",
    context = { includeDeclaration = true },
  },
  implementation = {
    method = "textDocument/implementation",
    label = "implementations",
    presentation = "jump_or_list",
  },
  type_definition = {
    method = "textDocument/typeDefinition",
    label = "type definitions",
    presentation = "jump_or_list",
  },
  incoming_calls = {
    method = "callHierarchy/incomingCalls",
    prepare_method = "textDocument/prepareCallHierarchy",
    label = "incoming calls",
    presentation = "always_list",
    direction = "incoming",
  },
  outgoing_calls = {
    method = "callHierarchy/outgoingCalls",
    prepare_method = "textDocument/prepareCallHierarchy",
    label = "outgoing calls",
    presentation = "always_list",
    direction = "outgoing",
  },
}

local internal = {
  manual = { method = "voyager/manual", label = "manual jump", presentation = "none" },
}

local M = {}

function M.names()
  return vim.deepcopy(order)
end

function M.get(name)
  assert(records[name], "unknown Voyager LSP action: " .. tostring(name))
  return vim.deepcopy(records[name])
end

function M.by_method(method)
  for _, name in ipairs(order) do
    if records[name].method == method then
      return name, vim.deepcopy(records[name])
    end
  end
  if internal.manual.method == method then
    return "manual", vim.deepcopy(internal.manual)
  end
end

return M
```

- [ ] **Step 4: Specify defaults and path-specific failures**

Create `tests/unit/config_spec.lua` with these cases:

```lua
local Config = require("voyager.config")

describe("Voyager configuration", function()
  it("returns an isolated complete snapshot", function()
    local first = Config.resolve({ sidebar = { width = 50 } })
    local second = Config.resolve({})
    assert.same(50, first.sidebar.width)
    assert.same(42, second.sidebar.width)
    assert.same("grr", second.lsp_keymaps.references)
    assert.same({ "q", "<Esc>" }, second.sidebar_keymaps.close)
  end)

  it("accepts disabled mappings and a URI resolver", function()
    local resolver = function()
      return 7
    end
    local config = Config.resolve({
      lsp_keymaps = { declaration = false },
      sidebar_keymaps = { close = false },
      storage = { resolve_uri = resolver },
    })
    assert.is_false(config.lsp_keymaps.declaration)
    assert.is_false(config.sidebar_keymaps.close)
    assert.equals(resolver, config.storage.resolve_uri)
  end)

  it("rejects invalid values with their full path", function()
    assert.has_error(function()
      Config.resolve({ sidebar = { side = "top" } })
    end, "voyager.setup: sidebar.side must be 'left' or 'right'")
    assert.has_error(function()
      Config.resolve({ lsp_keymaps = { definition = "" } })
    end, "voyager.setup: lsp_keymaps.definition must be false or a non-empty normal-mode LHS")
    assert.has_error(function()
      Config.resolve({ sidebar_keymaps = { close = {} } })
    end, "voyager.setup: sidebar_keymaps.close must not be an empty list")
    assert.has_error(function()
      Config.resolve({ lsp_keymaps = { definition = "gd", declaration = "gd" } })
    end, "voyager.setup: lsp_keymaps contains duplicate normalized LHS 'gd'")
  end)
end)
```

- [ ] **Step 5: Implement strict configuration resolution**

Create `lua/voyager/config.lua` with the exact default object from the design spec and this public contract:

```lua
local defaults = {
  sidebar = { width = 42, side = "right", border = "rounded" },
  navigation = { loclist = false, reuse_win = false, timeout_ms = 10000, on_list = nil },
  lsp_keymaps = {
    definition = "gd",
    declaration = "gD",
    references = "grr",
    implementation = "gri",
    type_definition = "grt",
    incoming_calls = "gC",
    outgoing_calls = "gG",
  },
  sidebar_keymaps = {
    jump_or_toggle = "<CR>",
    note = "n",
    save = "s",
    load = "L",
    toggle = "za",
    close = { "q", "<Esc>" },
  },
  storage = { resolve_uri = nil },
}

local known = {
  sidebar = { width = true, side = true, border = true },
  navigation = { loclist = true, reuse_win = true, timeout_ms = true, on_list = true },
  lsp_keymaps = {
    definition = true,
    declaration = true,
    references = true,
    implementation = true,
    type_definition = true,
    incoming_calls = true,
    outgoing_calls = true,
  },
  sidebar_keymaps = {
    jump_or_toggle = true,
    note = true,
    save = true,
    load = true,
    toggle = true,
    close = true,
  },
  storage = { resolve_uri = true },
}

local borders = { none = true, single = true, double = true, rounded = true, solid = true, shadow = true }

local function fail(path, message)
  error("voyager.setup: " .. path .. " " .. message, 0)
end

local function validate_lhs(path, value, allow_list)
  if value == false then
    return {}
  end
  local values = allow_list and type(value) == "table" and value or { value }
  if allow_list and type(value) == "table" and #value == 0 then
    fail(path, "must not be an empty list")
  end
  for _, lhs in ipairs(values) do
    local ok, normalized = false, nil
    if type(lhs) == "string" then
      ok, normalized = pcall(vim.keycode, lhs)
    end
    if not ok or lhs == "" or normalized == "" then
      fail(path, "must be false or a non-empty normal-mode LHS")
    end
  end
  return values
end

local function reject_unknown(scope, supplied, known)
  for key in pairs(supplied or {}) do
    if known[key] == nil then
      fail(scope .. "." .. tostring(key), "is not a supported option")
    end
  end
end

local M = {}

function M.resolve(opts)
  if opts ~= nil and type(opts) ~= "table" then
    fail("opts", "must be a table")
  end
  opts = opts or {}
  reject_unknown("opts", opts, known)
  for section, supplied in pairs(opts) do
    if type(supplied) ~= "table" then
      fail(section, "must be a table")
    end
    reject_unknown(section, supplied, known[section])
  end

  local result = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  for key, value in pairs(opts.sidebar_keymaps or {}) do
    result.sidebar_keymaps[key] = vim.deepcopy(value)
  end

  if type(result.sidebar.width) ~= "number" or result.sidebar.width % 1 ~= 0 or result.sidebar.width < 20 then
    fail("sidebar.width", "must be an integer of at least 20")
  end
  if result.sidebar.side ~= "left" and result.sidebar.side ~= "right" then
    fail("sidebar.side", "must be 'left' or 'right'")
  end
  if not borders[result.sidebar.border] then
    fail("sidebar.border", "must be a supported NUI border")
  end
  if type(result.navigation.loclist) ~= "boolean" then
    fail("navigation.loclist", "must be a boolean")
  end
  if type(result.navigation.reuse_win) ~= "boolean" then
    fail("navigation.reuse_win", "must be a boolean")
  end
  local timeout = result.navigation.timeout_ms
  if type(timeout) ~= "number" or timeout % 1 ~= 0 or timeout < 100 or timeout > 120000 then
    fail("navigation.timeout_ms", "must be an integer from 100 through 120000")
  end
  if result.navigation.on_list ~= nil and not vim.is_callable(result.navigation.on_list) then
    fail("navigation.on_list", "must be callable or nil")
  end
  if result.storage.resolve_uri ~= nil and not vim.is_callable(result.storage.resolve_uri) then
    fail("storage.resolve_uri", "must be callable or nil")
  end

  for group_name, allow_list in pairs({ lsp_keymaps = false, sidebar_keymaps = true }) do
    local seen = {}
    for key, value in pairs(result[group_name]) do
      for _, lhs in ipairs(validate_lhs(group_name .. "." .. key, value, allow_list)) do
        local normalized = vim.keycode(lhs)
        if seen[normalized] then
          fail(group_name, "contains duplicate normalized LHS '" .. lhs .. "'")
        end
        seen[normalized] = true
      end
    end
  end
  return vim.deepcopy(result)
end

return M
```

- [ ] **Step 6: Run focused and aggregate tests**

Run: `make test-unit TEST_FILE=tests/unit/actions_spec.lua`

Run: `make test-unit TEST_FILE=tests/unit/config_spec.lua`

Run: `make test-unit`

Expected: all PASS.

- [ ] **Step 7: Commit configuration**

```bash
git add lua/voyager/config.lua lua/voyager/lsp/actions.lua tests/unit/actions_spec.lua tests/unit/config_spec.lua
git commit -m "feat: validate Voyager configuration"
```

### Task 3: Canonical locators, ranges, and identities

**Files:**
- Create: `lua/voyager/locator.lua`
- Create: `tests/unit/locator_spec.lua`
- Create: `tests/helpers/buffer.lua`

- [ ] **Step 1: Write table-driven locator and encoding tests**

Create `tests/unit/locator_spec.lua` covering these exact assertions:

```lua
local Locator = require("voyager.locator")
local Buffer = require("tests.helpers.buffer")

describe("Voyager locators", function()
  it("converts client positions to UTF-8 byte columns", function()
    local lines = { "a😀b" }
    assert.same({
      start = { line = 0, character = 1 },
      ["end"] = { line = 0, character = 5 },
    }, Locator.canonical_range(lines, {
      start = { line = 0, character = 1 },
      ["end"] = { line = 0, character = 3 },
    }, "utf-16"))
  end)

  it("uses tagged canonical keys", function()
    assert.equals('["project","lua/auth.lua"]', Locator.locator_key({ kind = "project", path = "lua/auth.lua" }))
    assert.equals('["uri","jdt://contents/Foo.class"]', Locator.locator_key({
      kind = "uri",
      uri = "jdt://contents/Foo.class",
    }))
  end)

  it("reproduces the approved root hash and name", function()
    local root = {
      locator = { kind = "project", path = "lua/auth.lua" },
      range = { start = { line = 42, character = 0 }, ["end"] = { line = 42, character = 9 } },
      symbol = "authorize",
    }
    assert.equals("d70ea46c382e0db859f48f1d97a83658e86c8751baad3d0830ef8f04b461cccf", Locator.root_key(root))
    assert.equals("authorize", Locator.flow_name(root))
    assert.equals("authorize-d70ea46c", Locator.flow_id(root, 8))
  end)

  it("uses filename and one-based line for anonymous roots", function()
    local root = {
      locator = { kind = "project", path = "lua/auth.lua" },
      range = { start = { line = 4, character = 0 }, ["end"] = { line = 4, character = 0 } },
      symbol = "<anonymous>",
    }
    assert.equals("auth.lua:5", Locator.flow_name(root))
    assert.matches("^auth%-lua%-5%-[0-9a-f]+$", Locator.flow_id(root, 8))
  end)
end)
```

Add the following boundary and source-resolution examples to the same file. `tests/helpers/buffer.lua` must expose `Buffer.new(spec)`, returning `{ runtime, buffers, files }`; `runtime.find_buffer(name)` returns only an exact, valid, loaded name match, and every fake operation appends its name to `runtime.calls` so the loaded-buffer-first assertions are observable.

```lua
it("rejects malformed, clamped, and reversed protocol ranges", function()
  local lines = { "a😀b", "tail" }
  for _, range in ipairs({
    { start = { line = 0, character = -1 }, ["end"] = { line = 0, character = 0 } },
    { start = { line = 0, character = 10 }, ["end"] = { line = 0, character = 10 } },
    -- UTF-16 offset 2 splits the emoji's surrogate pair and has no UTF-8 byte boundary.
    { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 3 } },
    { start = { line = 1, character = 0 }, ["end"] = { line = 0, character = 0 } },
  }) do
    local converted, reason = Locator.canonical_range(lines, range, "utf-16")
    assert.is_nil(converted)
    assert.is_string(reason)
  end
end)

it("prefers an exact loaded named-unsaved buffer over disk", function()
  local env = Buffer.new({
    files = { ["/project/lua/new.lua"] = { "disk" } },
    buffers = { { id = 17, name = "/project/lua/new.lua", loaded = true, lines = { "unsaved" } } },
  })
  local locator = Locator.new(env.runtime, "/project", nil)
  assert.same({ "unsaved" }, locator:source({ kind = "project", path = "lua/new.lua" }))
  assert.same({ "find_buffer:/project/lua/new.lua", "get_buffer_lines:17" }, env.runtime.calls)
end)

it("normalizes file locators and reads an unloaded target without adding a buffer", function()
  local env = Buffer.new({ files = { ["/project/lua/auth.lua"] = { "return true" } } })
  local locator = Locator.new(env.runtime, "/project/./", nil)
  assert.same({ kind = "project", path = "lua/auth.lua" }, locator:from_uri("file:///project/lua/../lua/auth.lua"))
  assert.same({ "return true" }, locator:source({ kind = "project", path = "lua\\auth.lua" }))
  assert.same({}, env.buffers)
end)

it("requires an exact loaded non-file URI or a valid resolver result", function()
  local env = Buffer.new({
    buffers = {
      { id = 21, name = "jdt://contents/Foo.class", loaded = true, lines = { "class Foo" } },
      { id = 22, name = "resolver://backing", loaded = true, lines = { "class Bar" } },
    },
  })
  local locator = Locator.new(env.runtime, "/project", function(uri)
    return uri == "jdt://contents/Bar.class" and 22 or nil
  end)
  assert.same({ "class Foo" }, locator:source({ kind = "uri", uri = "jdt://contents/Foo.class" }))
  assert.same({ "class Bar" }, locator:source({ kind = "uri", uri = "jdt://contents/Bar.class" }))
  local lines, reason = locator:source({ kind = "uri", uri = "jdt://contents/Missing.class" })
  assert.is_nil(lines)
  assert.equals("non-file URI has no loaded source", reason)
end)

it("checks staleness and opens file targets only on demand", function()
  local env = Buffer.new({ files = { ["/project/lua/auth.lua"] = { "abc" } } })
  local locator = Locator.new(env.runtime, "/project", nil)
  local location = {
    locator = { kind = "project", path = "lua/auth.lua" },
    range = { start = { line = 0, character = 1 }, ["end"] = { line = 0, character = 3 } },
    symbol = "bc",
  }
  assert.is_false(locator:is_stale(location))
  assert.same({ bufnr = 1, row = 1, col = 1 }, locator:open_target(location))
  assert.is_true(env.buffers[1].listed)
  location.range["end"].character = 4
  assert.is_true(locator:is_stale(location))
end)

it("uses deterministic slug and node-ID inputs", function()
  local next_id = Locator.id_factory("authorize-d70ea46c", string.rep("\1", 16), 40, function(input)
    return vim.fn.sha256(input)
  end)
  assert.matches("^loc%-[0-9a-f][0-9a-f]+$", next_id("location"))
  assert.matches("^action%-[0-9a-f][0-9a-f]+$", next_id("action"))
  assert.equals("a-b-c", Locator.slug(" A😀B/Ç "))
end)
```

- [ ] **Step 2: Run the locator test red**

Run: `make test-unit TEST_FILE=tests/unit/locator_spec.lua`

Expected: FAIL with `module 'voyager.locator' not found`.

- [ ] **Step 3: Implement the canonical position primitives**

Create `lua/voyager/locator.lua` with these exact primitives first:

```lua
local M = {}

local function canonical_json(value)
  return vim.json.encode(value)
end

function M.canonical_range(lines, range, encoding)
  if type(lines) ~= "table"
    or type(range) ~= "table"
    or type(range.start) ~= "table"
    or type(range["end"]) ~= "table"
    or (encoding ~= "utf-8" and encoding ~= "utf-16" and encoding ~= "utf-32")
  then
    return nil, "range, source lines, or position encoding is invalid"
  end
  local function position(value)
    if type(value) ~= "table"
      or type(value.line) ~= "number"
      or value.line % 1 ~= 0
      or value.line < 0
      or type(value.character) ~= "number"
      or value.character % 1 ~= 0
      or value.character < 0
    then
      return nil, "position must contain non-negative integer line and character"
    end
    local line = lines[value.line + 1]
    if line == nil then
      return nil, "line is outside source bounds"
    end
    local ok, byte = pcall(vim.str_byteindex, line, encoding, value.character, true)
    if not ok or byte < 0 or byte > #line then
      return nil, "character is outside source bounds"
    end
    -- `str_byteindex` rounds an offset inside a UTF-16 surrogate pair. A strict
    -- round trip rejects that offset instead of silently changing the range.
    local roundtrip_ok, character = pcall(vim.str_utfindex, line, encoding, byte, true)
    if not roundtrip_ok or character ~= value.character then
      return nil, "character is not on an encoding boundary"
    end
    return { line = value.line, character = byte }
  end

  local start_pos, start_error = position(range.start)
  if not start_pos then
    return nil, start_error
  end
  local end_pos, end_error = position(range["end"])
  if not end_pos then
    return nil, end_error
  end
  if end_pos.line < start_pos.line
    or (end_pos.line == start_pos.line and end_pos.character < start_pos.character)
  then
    return nil, "range end precedes range start"
  end
  return { start = start_pos, ["end"] = end_pos }
end

function M.locator_key(locator)
  return canonical_json({ locator.kind, locator.path or locator.uri })
end

function M.location_key(location)
  local range = location.range
  return canonical_json({
    location.locator.kind,
    location.locator.path or location.locator.uri,
    range.start.line,
    range.start.character,
    range["end"].line,
    range["end"].character,
  })
end

function M.contains(location, locator, cursor)
  if M.locator_key(location.locator) ~= M.locator_key(locator) then
    return false
  end
  local range = location.range
  if range.start.line == range["end"].line and range.start.character == range["end"].character then
    return cursor.line == range.start.line and cursor.character == range.start.character
  end
  local after_start = cursor.line > range.start.line
    or (cursor.line == range.start.line and cursor.character >= range.start.character)
  local before_end = cursor.line < range["end"].line
    or (cursor.line == range["end"].line and cursor.character < range["end"].character)
  return after_start and before_end
end
```

- [ ] **Step 4: Add path/URI source resolution and identity functions**

Use one injectable runtime contract. Task 6's `Runtime.native()` must provide the same names; `tests/helpers/buffer.lua` supplies the deterministic fake used above.

```lua
---@class VoyagerLocatorRuntime
---@field fs_realpath fun(path:string):string?
---@field fs_stat fun(path:string):table?
---@field read_file fun(path:string):string[]|nil,string?
---@field find_buffer fun(exact_name:string):integer?
---@field buffer_valid fun(bufnr:integer):boolean
---@field buffer_loaded fun(bufnr:integer):boolean
---@field buffer_name fun(bufnr:integer):string
---@field get_buffer_lines fun(bufnr:integer):string[]
---@field add_buffer fun(exact_name:string):integer
---@field load_buffer fun(bufnr:integer):boolean,string?
---@field set_buffer_listed fun(bufnr:integer, listed:boolean)
---@field cursor fun(winid:integer):table -- `{ line = zero_based, character = byte_column }`
---@field word_at_cursor fun(bufnr:integer, winid:integer):string,integer,integer
---@field word_at fun(lines:string[], line:integer, byte_col:integer, bufnr:integer?):string?
---@field random fun(length:integer):string?
---@field sha256 fun(input:string):string
```

Implement these signatures and return `(nil, reason)` rather than throwing for stale or unresolvable targets:

```lua
Locator.new(runtime, project_root, resolve_uri) --> locator_service
locator_service:from_uri(uri) --> VoyagerLocator
locator_service:source(locator) --> lines|nil, reason
locator_service:list_target(locator) --> { bufnr = integer }|{ filename = absolute_path }|nil, reason
locator_service:metadata(locator, lines, range, preferred_symbol) --> symbol, context?
locator_service:is_stale(location) --> boolean, reason?
locator_service:open_target(location) --> { bufnr, row, col }|nil, reason
Locator.capture_root(bufnr, winid, project_root, runtime) --> VoyagerLocation
Locator.root_key(root) --> 64-character lowercase SHA-256
Locator.flow_name(root) --> string
Locator.flow_id(root, hash_length) --> string
Locator.slug(name) --> ASCII slug
Locator.id_factory(flow_id, nonce_bytes, initial_counter, sha256) --> fun(kind:"location"|"action"):string
```

`from_uri` must decode file URIs, compare normalized real paths with a path-boundary check (never a raw prefix check), emit a `/`-separated project-relative locator when contained, and otherwise emit an absolute locator. Non-file URIs stay byte-for-byte unchanged. `source` resolves project paths against the fixed real project root; it asks `find_buffer` before `read_file`. For a URI, it first asks `find_buffer(uri)`, then invokes `resolve_uri(uri)` and accepts the result only when it is a valid loaded buffer. `list_target` returns the loaded `bufnr` when one exists, an absolute filename for a file locator otherwise, and never creates a buffer. `metadata` uses a non-empty protocol `preferred_symbol` first, then `runtime.word_at` at the normalized start, then `<basename>:<one-based-line>`; it returns the unmodified source line as optional non-empty `context`. `is_stale` validates both endpoints and range ordering against those authoritative lines. `open_target` calls `source` first, reuses its loaded buffer when present, and only then calls `add_buffer`/`load_buffer` for a file locator; it marks that destination listed and returns one-based row plus zero-based byte column. It never creates a buffer during `source` or normalization.

The ID factory must use this input verbatim:

```lua
local prefix = kind == "location" and "loc" or "action"
local digest = sha256(flow_id .. "\0" .. nonce_hex .. "\0" .. kind .. "\0" .. tostring(counter))
return prefix .. "-" .. digest:sub(1, 32)
```

The slug algorithm lowercases ASCII `A-Z`, preserves only ASCII `a-z0-9`, converts each other codepoint run to one hyphen, trims edges, truncates to 48 ASCII characters, and falls back to `anonymous`.

- [ ] **Step 5: Run the locator matrix**

Run: `make test-unit TEST_FILE=tests/unit/locator_spec.lua`

Expected: all locator, encoding, stale, anonymous-name, root-hash, and ID cases PASS.

- [ ] **Step 6: Commit canonical locations**

```bash
git add lua/voyager/locator.lua tests/unit/locator_spec.lua tests/helpers/buffer.lua
git commit -m "feat: canonicalize Voyager locations"
```

### Task 4: Pure branching flow model

**Files:**
- Create: `lua/voyager/flow.lua`
- Create: `tests/helpers/flow.lua`
- Create: `tests/unit/flow_spec.lua`

- [ ] **Step 1: Define the tree construction and branch tests**

Create `tests/helpers/flow.lua` with deterministic root, clock, document, and ID helpers:

```lua
local Flow = require("voyager.flow")
local Locator = require("voyager.locator")

local M = {}

function M.identity(path, line)
  return string.format('["project","%s",%d,0,%d,4]', path, line, line)
end

function M.location(path, line, symbol, context)
  return {
    locator = { kind = "project", path = path },
    range = {
      start = { line = line, character = 0 },
      ["end"] = { line = line, character = 4 },
    },
    symbol = symbol or "symbol",
    context = context,
    identity = M.identity(path, line),
  }
end

function M.factories()
  local counter = 0
  return function()
    return "2026-08-01T18:25:43Z"
  end, function(kind)
    counter = counter + 1
    local prefix = kind == "location" and "loc" or "action"
    return string.format("%s-%032x", prefix, counter)
  end
end

function M.document()
  local root_location = M.location("lua/main.lua", 0, "main")
  root_location.identity = nil
  local root_key = Locator.root_key(root_location)
  return {
    schema_version = 1,
    position_encoding = "utf-8",
    revision = 3,
    flow_id = Locator.flow_id(root_location, 8),
    name = Locator.flow_name(root_location),
    root_key = root_key,
    created_at = "2026-08-01T18:25:43Z",
    updated_at = "2026-08-01T18:41:02Z",
    current_node_id = "loc-00000000000000000000000000000001",
    root = {
      id = "loc-00000000000000000000000000000001",
      kind = "location",
      location = root_location,
      note = nil,
      actions = {},
    },
  }
end

function M.new_flow()
  local now, next_id = M.factories()
  local root = M.location("lua/main.lua", 0, "main")
  root.identity = nil
  local root_key = Locator.root_key(root)
  return Flow.new({
    root = root,
    name = Locator.flow_name(root),
    flow_id = Locator.flow_id(root, 8),
    root_key = root_key,
    now = now,
    next_id = next_id,
  })
end

function M.branched_flow()
  local flow = M.new_flow()
  local mysql = M.location("lua/mysql.lua", 2, "MysqlStore.save")
  local memory = M.location("lua/memory.lua", 3, "MemoryStore.save")
  local commit = flow:commit_navigation({
    origin_node_id = flow.root.id,
    method = "textDocument/implementation",
    label = "implementations",
    locations = { mysql, memory },
  })
  flow:set_note(commit.node_id_by_identity[mysql.identity], "important for auth")
  return flow
end

return M
```

Create `tests/unit/flow_spec.lua` with this first journey:

```lua
local Flow = require("voyager.flow")
local Fixtures = require("tests.helpers.flow")

describe("Voyager flow", function()
  it("keeps sibling branches while extending a selected result", function()
    local flow = Fixtures.new_flow()
    local first = flow:commit_navigation({
      origin_node_id = flow.root.id,
      method = "textDocument/implementation",
      label = "implementations",
      locations = {
        Fixtures.location("lua/mysql.lua", 2, "MysqlStore.save"),
        Fixtures.location("lua/memory.lua", 3, "MemoryStore.save"),
      },
    })
    local mysql_id = first.node_id_by_identity[Fixtures.identity("lua/mysql.lua", 2)]
    flow:set_current(mysql_id)
    flow:commit_navigation({
      origin_node_id = mysql_id,
      method = "textDocument/references",
      label = "references",
      locations = { Fixtures.location("lua/auth.lua", 8, "AuthService.login") },
    })

    assert.equals(2, #flow.root.actions[1].results)
    assert.equals("textDocument/references", flow.root.actions[1].results[1].actions[1].method)
    assert.same({}, flow.root.actions[1].results[2].actions)
  end)
end)
```

Add these examples below the first journey:

```lua
it("reuses one action and deduplicates repeated results", function()
  local flow = Fixtures.new_flow()
  local mysql = Fixtures.location("lua/mysql.lua", 2, "MysqlStore.save")
  local memory = Fixtures.location("lua/memory.lua", 3, "MemoryStore.save")
  local first = flow:commit_navigation({
    origin_node_id = flow.root.id,
    method = "textDocument/implementation",
    label = "implementations",
    locations = { mysql },
  })
  local second = flow:commit_navigation({
    origin_node_id = flow.root.id,
    method = "textDocument/implementation",
    label = "implementations",
    locations = { mysql, memory },
  })

  assert.equals(first.action_id, second.action_id)
  assert.equals(first.node_id_by_identity[mysql.identity], second.node_id_by_identity[mysql.identity])
  assert.equals(2, #flow.root.actions[1].results)
end)

it("keeps the same destination distinct beneath different ancestors", function()
  local flow = Fixtures.new_flow()
  local branches = flow:commit_navigation({
    origin_node_id = flow.root.id,
    method = "textDocument/implementation",
    label = "implementations",
    locations = {
      Fixtures.location("lua/mysql.lua", 2, "MysqlStore.save"),
      Fixtures.location("lua/memory.lua", 3, "MemoryStore.save"),
    },
  })
  local auth = Fixtures.location("lua/auth.lua", 8, "AuthService.login")
  local mysql = flow:commit_navigation({
    origin_node_id = branches.node_id_by_identity[Fixtures.identity("lua/mysql.lua", 2)],
    method = "textDocument/references",
    label = "references",
    locations = { auth },
  })
  local memory = flow:commit_navigation({
    origin_node_id = branches.node_id_by_identity[Fixtures.identity("lua/memory.lua", 3)],
    method = "textDocument/references",
    label = "references",
    locations = { auth },
  })

  assert.not_equals(mysql.node_id_by_identity[auth.identity], memory.node_id_by_identity[auth.identity])
end)

it("keeps an empty action visible and treats its repeat as a no-op", function()
  local flow = Fixtures.new_flow()
  local first = flow:commit_navigation({
    origin_node_id = flow.root.id,
    method = "textDocument/references",
    label = "references",
    locations = {},
  })
  local second = flow:commit_navigation({
    origin_node_id = flow.root.id,
    method = "textDocument/references",
    label = "references",
    locations = {},
  })

  assert.is_true(first.changed)
  assert.is_false(second.changed)
  assert.equals(first.action_id, second.action_id)
  assert.same({}, flow.root.actions[1].results)
end)

it("finds nested nodes and returns nil for an unknown ID", function()
  local flow = Fixtures.new_flow()
  local commit = flow:commit_navigation({
    origin_node_id = flow.root.id,
    method = "textDocument/definition",
    label = "definition",
    locations = { Fixtures.location("lua/auth.lua", 8, "AuthService.login") },
  })
  local result_id = commit.node_id_by_identity[Fixtures.identity("lua/auth.lua", 8)]

  assert.equals(result_id, flow:find(result_id).id)
  assert.is_nil(flow:find("loc-ffffffffffffffffffffffffffffffff"))
end)

it("walks location, action, and result nodes in stable depth-first order", function()
  local flow = Fixtures.new_flow()
  local commit = flow:commit_navigation({
    origin_node_id = flow.root.id,
    method = "textDocument/implementation",
    label = "implementations",
    locations = {
      Fixtures.location("lua/mysql.lua", 2, "MysqlStore.save"),
      Fixtures.location("lua/memory.lua", 3, "MemoryStore.save"),
    },
  })
  local mysql_id = commit.node_id_by_identity[Fixtures.identity("lua/mysql.lua", 2)]
  local memory_id = commit.node_id_by_identity[Fixtures.identity("lua/memory.lua", 3)]
  local references = flow:commit_navigation({
    origin_node_id = mysql_id,
    method = "textDocument/references",
    label = "references",
    locations = { Fixtures.location("lua/auth.lua", 8, "AuthService.login") },
  })
  local ids = vim.tbl_map(function(node)
    return node.id
  end, flow:dfs())

  assert.same({
    flow.root.id,
    commit.action_id,
    mysql_id,
    references.action_id,
    references.node_id_by_identity[Fixtures.identity("lua/auth.lua", 8)],
    memory_id,
  }, ids)
end)
```

- [ ] **Step 2: Run the branch test red**

Run: `make test-unit TEST_FILE=tests/unit/flow_spec.lua`

Expected: FAIL with `module 'voyager.flow' not found`.

- [ ] **Step 3: Implement constructors, indexing, and navigation commits**

Use this public shape:

```lua
local flow = Flow.new({
  root = root_location,
  name = flow_name,
  flow_id = flow_id,
  root_key = root_key,
  now = injected_clock,
  next_id = injected_id_factory,
})

flow:find(node_id) --> node|nil
flow:location(node_id) --> location_node|nil
flow:dfs() --> stable_preorder_array
flow:commit_navigation(input) --> commit_result
flow:set_current(node_id) --> changed
flow:set_note(node_id, normalized_note_or_nil) --> changed
flow:toggle(action_id) --> changed
flow:is_dirty() --> boolean
flow:journal() --> deep-copied journal
flow:mark_saved(merged_document)
Flow.from_document(document, { now = injected_clock, next_id = injected_id_factory }) --> clean_flow
```

`Flow.new` creates `schema_version = 1`, `position_encoding = "utf-8"`, transient `revision = 0`, `created_at`/`updated_at` from the injected clock, the supplied name/flow/root identity fields, `current_node_id = root.id`, and the root location node. `Flow.from_document` validates the persisted positive revision upstream, rebuilds the ID index, starts with an empty mutation journal, and is clean.

`commit_navigation` accepts `origin_node_id`, optional `manual_location`, canonical `method`, `label`, and unique `locations`. Input locations carry a transient `identity`; use it for result deduplication and the return map, but remove it before assigning `node.location` so it is never serialized. It must return:

```lua
{
  effective_origin_id = "loc-11111111111111111111111111111111",
  action_id = "action-22222222222222222222222222222222",
  node_id_by_identity = { [location.identity] = "loc-33333333333333333333333333333333" },
  changed = true,
}
```

Implement the alternating-node constructors exactly as follows:

```lua
local function location_node(id, location)
  return {
    id = id,
    kind = "location",
    location = vim.deepcopy(location),
    note = nil,
    actions = {},
  }
end

local function action_node(id, method, label)
  return {
    id = id,
    kind = "action",
    method = method,
    label = label,
    collapsed = false,
    results = {},
  }
end
```

Index every node by ID. At one location, reuse an action by method. Within one action, reuse a result by its `identity`, recursively retaining its child actions. When `manual_location` exists, build the `voyager/manual` action and manual result in a deep-copied flow, attach the requested action there, and replace the active tree only after both insertions succeed.

- [ ] **Step 4: Specify notes, current state, collapse, and dirty no-ops**

Add these assertions to `tests/unit/flow_spec.lua`:

```lua
it("journals persisted changes but ignores semantic no-ops", function()
  local flow = Fixtures.new_flow()
  assert.is_false(flow:is_dirty())
  assert.is_false(flow:set_current(flow.root.id))
  assert.is_true(flow:set_note(flow.root.id, "important for auth"))
  assert.is_false(flow:set_note(flow.root.id, "important for auth"))
  assert.is_true(flow:set_note(flow.root.id, nil))
  assert.is_false(flow:set_note(flow.root.id, nil))
  assert.same({ [flow.root.id] = { note = vim.NIL } }, flow:journal().notes)
end)
```

Add these cases; the empty-action example in Step 1 already proves the remaining dirty no-op:

```lua
it("accepts only locations as current and only actions as toggle targets", function()
  local flow = Fixtures.new_flow()
  local commit = flow:commit_navigation({
    origin_node_id = flow.root.id,
    method = "textDocument/definition",
    label = "definition",
    locations = {},
  })

  assert.has_error(function()
    flow:set_current(commit.action_id)
  end, "Voyager current node must be a location: " .. commit.action_id)
  assert.has_error(function()
    flow:toggle(flow.root.id)
  end, "Voyager toggle target must be an action: " .. flow.root.id)
  assert.is_true(flow:toggle(commit.action_id))
  assert.is_false(flow:toggle("action-ffffffffffffffffffffffffffffffff"))
end)

it("touches display metadata created on a non-root result", function()
  local flow = Fixtures.new_flow()
  local location = Fixtures.location("lua/auth.lua", 8, "AuthService.login", "return auth:login()")
  local commit = flow:commit_navigation({
    origin_node_id = flow.root.id,
    method = "textDocument/definition",
    label = "definition",
    locations = { location },
  })
  local result_id = commit.node_id_by_identity[location.identity]

  assert.same({ symbol = true, context = true }, flow:journal().metadata[result_id])
end)
```

- [ ] **Step 5: Implement mutation journals**

Keep journal state out of serialized nodes:

```lua
{
  notes = {},
  metadata = {},
  collapsed = {},
  current_node_id = false,
}
```

Use `vim.NIL` only inside the transient note journal to distinguish an explicit clear from untouched state. A new root marks root metadata/current as merge-touched without marking the root-only flow dirty. Every public mutation returns `true` only when a persisted value changes.

- [ ] **Step 6: Run and commit the flow model**

Run: `make test-unit TEST_FILE=tests/unit/flow_spec.lua`

Run: `make test-unit`

Expected: all PASS.

```bash
git add lua/voyager/flow.lua tests/helpers/flow.lua tests/unit/flow_spec.lua
git commit -m "feat: model branching navigation flows"
```

### Task 5: Recursive merge and strict canonical schema

**Files:**
- Modify: `lua/voyager/flow.lua`
- Create: `lua/voyager/schema.lua`
- Create: `tests/unit/schema_spec.lua`
- Modify: `tests/unit/flow_spec.lua`

- [ ] **Step 1: Write merge-precedence tests before merge code**

Extend `tests/unit/flow_spec.lua` with these local constructors and independently constructed `latest` and `active` documents:

```lua
local function node_id(kind, value)
  local prefix = kind == "location" and "loc" or kind
  return string.format("%s-%032x", prefix, value)
end

local function location_node(value, path, line, symbol, context)
  local location = Fixtures.location(path, line, symbol, context)
  location.identity = nil
  return {
    id = node_id("loc", value),
    kind = "location",
    location = location,
    note = nil,
    actions = {},
  }
end

local function action_node(value, method, label, results, collapsed)
  return {
    id = node_id("action", value),
    kind = "action",
    method = method,
    label = label,
    collapsed = collapsed or false,
    results = results or {},
  }
end

local function document(root, current_node_id)
  local value = Fixtures.document()
  value.root = root
  value.current_node_id = current_node_id or root.id
  return value
end

local function load(document_value, next_id)
  local now = function()
    return "2026-08-01T19:00:00Z"
  end
  return Flow.from_document(document_value, { now = now, next_id = next_id or select(2, Fixtures.factories()) })
end

it("keeps disk order, retains active IDs on matches, and appends active-only children", function()
  local latest_root = location_node(1, "lua/main.lua", 0, "main")
  local latest_mysql = location_node(12, "lua/mysql.lua", 2, "MysqlStore.save")
  latest_root.actions = {
    action_node(10, "textDocument/references", "stale references", {}),
    action_node(11, "textDocument/implementation", "stale implementations", { latest_mysql }),
  }
  local latest = document(latest_root)

  local active_root = location_node(2, "lua/main.lua", 0, "main")
  local active_mysql = location_node(22, "lua/mysql.lua", 2, "MysqlStore.save")
  active_root.actions = {
    action_node(21, "textDocument/implementation", "wrong label", { active_mysql }),
    action_node(23, "textDocument/definition", "definition", {}),
  }
  local active = load(document(active_root))
  local merged = Flow.merge(latest, active, active:journal(), active._next_id)

  assert.equals(latest.created_at, merged.created_at)
  assert.equals(latest.revision + 1, merged.revision)
  assert.same({
    "textDocument/references",
    "textDocument/implementation",
    "textDocument/definition",
  }, vim.tbl_map(function(action)
    return action.method
  end, merged.root.actions))
  assert.equals(node_id("action", 10), merged.root.actions[1].id)
  assert.equals(node_id("action", 21), merged.root.actions[2].id)
  assert.equals(node_id("loc", 22), merged.root.actions[2].results[1].id)
  assert.equals(node_id("action", 23), merged.root.actions[3].id)
  assert.same({ "references", "implementations", "definition" }, vim.tbl_map(function(action)
    return action.label
  end, merged.root.actions))
  assert.equals(active.root.id, merged.root.id)
end)

it("applies journal precedence to notes, collapse, current, and display metadata", function()
  local latest_root = location_node(1, "lua/main.lua", 0, "main")
  local latest_result = location_node(3, "lua/auth.lua", 8, "disk symbol", "disk context")
  latest_root.note = "disk note"
  latest_root.actions = {
    action_node(2, "textDocument/definition", "definition", { latest_result }, true),
  }
  local latest = document(latest_root, latest_result.id)

  local active_root = location_node(11, "lua/main.lua", 0, "main")
  local active_result = location_node(13, "lua/auth.lua", 8, "old active symbol", "old active context")
  active_root.note = "old active note"
  active_root.actions = {
    action_node(12, "textDocument/definition", "definition", { active_result }, true),
  }
  local active = load(document(active_root))

  local untouched = Flow.merge(latest, active, active:journal(), active._next_id)
  assert.equals("disk note", untouched.root.note)
  assert.is_true(untouched.root.actions[1].collapsed)
  assert.equals("disk symbol", untouched.root.actions[1].results[1].location.symbol)
  assert.equals(active_result.id, untouched.current_node_id)

  assert.is_true(active:set_note(active.root.id, "active note"))
  assert.is_true(active:toggle(active_root.actions[1].id))
  assert.is_true(active:set_current(active_result.id))
  active:commit_navigation({
    origin_node_id = active.root.id,
    method = "textDocument/definition",
    label = "definition",
    locations = { Fixtures.location("lua/auth.lua", 8, "active symbol", "active context") },
  })
  local touched = Flow.merge(latest, active, active:journal(), active._next_id)
  assert.equals("active note", touched.root.note)
  assert.is_false(touched.root.actions[1].collapsed)
  assert.equals("active symbol", touched.root.actions[1].results[1].location.symbol)
  assert.equals("active context", touched.root.actions[1].results[1].location.context)
  assert.equals(active_result.id, touched.current_node_id)

  assert.is_true(active:set_note(active.root.id, nil))
  local cleared = Flow.merge(latest, active, active:journal(), active._next_id)
  assert.is_nil(cleared.root.note)
end)

it("remaps colliding saved-only IDs and their current-node reference", function()
  local latest_root = location_node(1, "lua/main.lua", 0, "main")
  local saved_result = location_node(6, "lua/auth.lua", 8, "AuthService.login")
  latest_root.actions = {
    action_node(5, "textDocument/references", "references", { saved_result }),
  }
  local latest = document(latest_root, saved_result.id)

  local active_root = location_node(2, "lua/main.lua", 0, "main")
  active_root.actions = {
    action_node(5, "textDocument/definition", "definition", {
      location_node(6, "lua/mysql.lua", 2, "MysqlStore.save"),
    }),
  }
  local next_value = 90
  local active = load(document(active_root), function(kind)
    next_value = next_value + 1
    return node_id(kind, next_value)
  end)
  local merged = Flow.merge(latest, active, active:journal(), active._next_id)
  local imported = merged.root.actions[1]

  assert.equals("textDocument/references", imported.method)
  assert.not_equals(node_id("action", 5), imported.id)
  assert.not_equals(node_id("loc", 6), imported.results[1].id)
  assert.equals(imported.results[1].id, merged.current_node_id)
  assert.equals(node_id("action", 5), merged.root.actions[2].id)
end)

it("rejects changes to immutable root identity", function()
  local latest = Fixtures.document()
  local active_document = Fixtures.document()
  active_document.root.id = node_id("loc", 20)
  active_document.current_node_id = active_document.root.id
  active_document.root.location.symbol = "different-root-symbol"
  local active = load(active_document)

  assert.has_error(function()
    Flow.merge(latest, active, active:journal(), active._next_id)
  end, "Voyager merge requires identical root identity")
end)
```

These examples cover untouched disk precedence, explicit note clear, touched and untouched view/metadata state, unchanged saved-only IDs, collision remapping, current-reference remapping, disk-first deterministic order, active-only append order, immutable root identity, and active ID retention. Do not replace them with a single broad assertion.

- [ ] **Step 2: Run the merge examples red**

Run: `make test-unit TEST_FILE=tests/unit/flow_spec.lua`

Expected: FAIL because `Flow.merge` is absent.

- [ ] **Step 3: Implement recursive merge as a pure function**

Add this contract to `lua/voyager/flow.lua`:

```lua
Flow.merge(latest_document, active_flow, active_journal, next_id)
  --> merged_document
```

Merge action children by `method` and result children by `Locator.location_key(node.location)`. Build every child array in two explicit passes: walk the latest disk array first, recursively merging matches and importing disk-only subtrees in that exact order; then walk the active array and append only unmatched active-only children in their active exploration order. A matched node is constructed from the active node so its ID survives, while untouched persisted fields take their latest values and journal-touched fields take their active values. Never append disk-only children after active children.

Before importing a disk-only subtree, collect every active ID. Preserve an imported ID when unused; otherwise recursively replace it with `next_id(node.kind)` and record the old-to-new mapping. Resolve latest `current_node_id` through both the semantic match map and imported-ID map; a journal-touched active current node wins afterward. Apply note, metadata, collapsed, and current journal overrides only after structural merge. Reject differing root locator/range/symbol identities. Canonicalize every action label through `select(2, require("voyager.lsp.actions").by_method(method)).label`, derive `name` and `flow_id` from the root, preserve the latest `created_at`, and increment the latest revision; the store supplies the successful save's `updated_at`.

Also canonicalize labels recursively in `Flow.from_document`: persisted labels are readable schema fields, not authoritative runtime values. Add this load test:

```lua
it("replaces persisted action labels with registry labels on load", function()
  local document_value = Fixtures.document()
  document_value.root.actions = {
    action_node(2, "textDocument/implementation", "obsolete label", {}),
  }
  local flow = load(document_value)

  assert.equals("implementations", flow.root.actions[1].label)
end)
```

- [ ] **Step 4: Specify strict schema-v1 validation**

Create `tests/unit/schema_spec.lua` with the approved example document and assert:

```lua
local Schema = require("voyager.schema")
local Fixtures = require("tests.helpers.flow")

local function node_id(kind, value)
  local prefix = kind == "location" and "loc" or kind
  return string.format("%s-%032x", prefix, value)
end

local function location_node(value, path, line, symbol, context)
  local location = Fixtures.location(path, line, symbol, context)
  location.identity = nil
  return {
    id = node_id("loc", value),
    kind = "location",
    location = location,
    note = nil,
    actions = {},
  }
end

local function action_node(value, method, label, results, collapsed)
  return {
    id = node_id("action", value),
    kind = "action",
    method = method,
    label = label,
    collapsed = collapsed or false,
    results = results or {},
  }
end

it("round-trips canonical JSON byte-for-byte", function()
  local encoded = Schema.encode(Fixtures.document())
  assert.equals(encoded, Schema.encode(Schema.decode(encoded)))
  assert.matches('^%{%s+"schema_version": 1,', encoded)
  assert.matches('\n  "position_encoding": "utf%-8",', encoded)
  assert.matches('%}\n$', encoded)
end)

it("omits absent optional fields and rejects null", function()
  local document = Fixtures.document()
  document.root.note = nil
  document.root.location.context = nil
  local encoded = Schema.encode(document)
  assert.is_nil(encoded:match('"note"'))
  assert.is_nil(encoded:match('"context"'))
  assert.has_error(function()
    Schema.decode(encoded:gsub('"actions":', '"note": null, "actions":', 1))
  end)
end)

it("rejects unknown keys and semantic identity mismatches", function()
  local encoded = Schema.encode(Fixtures.document())
  assert.has_error(function()
    Schema.decode(encoded:gsub('"revision": 3', '"revision": 3, "mystery": true', 1))
  end, "schema v1: unknown key $.mystery")
end)
```

Add this table-driven rejection test rather than leaving the rejection matrix implicit:

```lua
it("rejects every schema-v1 structural and semantic violation", function()
  local cases = {
    { "newer version", function(d) d.schema_version = 2 end, "schema_version" },
    { "non-UTF-8 positions", function(d) d.position_encoding = "utf-16" end, "position_encoding" },
    { "zero revision", function(d) d.revision = 0 end, "revision" },
    { "invalid timestamp", function(d) d.updated_at = "2026-08-01" end, "updated_at" },
    { "invalid node kind", function(d) d.root.kind = "result" end, "kind" },
    { "duplicate ID", function(d)
      d.root.actions = { action_node(2, "textDocument/definition", "definition", {
        vim.tbl_extend("force", location_node(2, "lua/auth.lua", 8, "auth"), { id = d.root.id }),
      }) }
    end, "duplicate" },
    { "non-alternating child", function(d)
      d.root.actions = { location_node(2, "lua/auth.lua", 8, "auth") }
    end, "action" },
    { "missing current location", function(d) d.current_node_id = node_id("loc", 99) end, "current_node_id" },
    { "null optional", function(d) d.root.note = vim.NIL end, "note" },
    { "invalid locator", function(d) d.root.location.locator.path = "../escape.lua" end, "locator" },
    { "inverted range", function(d)
      d.root.location.range.start.character = 5
      d.root.location.range["end"].character = 1
    end, "range" },
    { "wrong root key", function(d) d.root_key = string.rep("b", 64) end, "root_key" },
    { "wrong name", function(d) d.name = "not-main" end, "name" },
    { "wrong flow ID", function(d) d.flow_id = "not-main-bbbbbbbb" end, "flow_id" },
    { "unknown action method", function(d)
      d.root.actions = { action_node(2, "textDocument/unknown", "unknown", {}) }
    end, "method" },
  }

  for _, case in ipairs(cases) do
    local document_value = Fixtures.document()
    case[2](document_value)
    local ok, err = pcall(Schema.validate, document_value)
    assert.is_false(ok, case[1])
    assert.matches(case[3], tostring(err), nil, true)
  end
end)
```

- [ ] **Step 5: Implement a deterministic encoder and strict decoder**

Create `lua/voyager/schema.lua` with:

```lua
Schema.validate(document) --> deep-copied validated document
Schema.encode(document) --> canonical_json_with_final_newline
Schema.decode(json_text) --> validated_document
```

Use `vim.json.decode` only for parsing. Validate each object against an explicit allowed-key set. Encode strings with `vim.json.encode`, but emit objects through ordered field arrays rather than Lua table iteration. The top-level order is `schema_version`, `position_encoding`, `revision`, `flow_id`, `name`, `root_key`, `created_at`, `updated_at`, `current_node_id`, `root`. Location node order is `id`, `kind`, `location`, optional `note`, `actions`; action node order is `id`, `kind`, `method`, `label`, `collapsed`, `results`. Use two spaces, LF, and exactly one final newline.

- [ ] **Step 6: Run schema and merge tests**

Run: `make test-unit TEST_FILE=tests/unit/schema_spec.lua`

Run: `make test-unit TEST_FILE=tests/unit/flow_spec.lua`

Expected: all PASS.

- [ ] **Step 7: Commit merge and schema**

```bash
git add lua/voyager/flow.lua lua/voyager/schema.lua tests/unit/flow_spec.lua tests/unit/schema_spec.lua
git commit -m "feat: merge and encode saved flows"
```

### Task 6: Runtime adapters and atomic flow storage

**Files:**
- Create: `lua/voyager/runtime.lua`
- Create: `lua/voyager/store.lua`
- Create: `tests/helpers/fake_fs.lua`
- Create: `tests/unit/store_spec.lua`

- [ ] **Step 1: Define a single injectable runtime boundary**

Create `lua/voyager/runtime.lua` returning a fresh table from `Runtime.native()` with these named functions:

```lua
local M = {}

function M.native()
  return {
    now = function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end,
    random = vim.uv.random,
    sha256 = vim.fn.sha256,
    pid = vim.uv.os_getpid,
    cwd = vim.fn.getcwd,
    dirname = vim.fs.dirname,
    find_root = function(path, marker) return vim.fs.root(path, marker) end,

    fs_realpath = vim.uv.fs_realpath,
    fs_stat = vim.uv.fs_stat,
    fs_scandir = vim.uv.fs_scandir,
    fs_scandir_next = vim.uv.fs_scandir_next,
    fs_open = vim.uv.fs_open,
    fs_read = vim.uv.fs_read,
    fs_write = vim.uv.fs_write,
    fs_fsync = vim.uv.fs_fsync,
    fs_close = vim.uv.fs_close,
    fs_rename = vim.uv.fs_rename,
    fs_unlink = vim.uv.fs_unlink,
    mkdir = function(path) return vim.fn.mkdir(path, "p") end,
    read_file = function(path)
      local ok, lines = pcall(vim.fn.readfile, path)
      if not ok then return nil, tostring(lines) end
      return lines
    end,

    list_buffers = vim.api.nvim_list_bufs,
    find_buffer = function(exact_name)
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr)
          and vim.api.nvim_buf_is_loaded(bufnr)
          and vim.api.nvim_buf_get_name(bufnr) == exact_name
        then
          return bufnr
        end
      end
    end,
    buffer_valid = vim.api.nvim_buf_is_valid,
    buffer_loaded = vim.api.nvim_buf_is_loaded,
    buffer_name = vim.api.nvim_buf_get_name,
    get_buffer_lines = function(bufnr)
      return vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
    end,
    add_buffer = vim.fn.bufadd,
    load_buffer = function(bufnr)
      local ok, result = pcall(vim.fn.bufload, bufnr)
      if not ok then return false, tostring(result) end
      return true
    end,
    set_buffer_listed = function(bufnr, listed)
      vim.api.nvim_set_option_value("buflisted", listed, { buf = bufnr })
    end,
    buffer_option = function(bufnr, name)
      return vim.api.nvim_get_option_value(name, { buf = bufnr })
    end,
    set_buffer_option = function(bufnr, name, value)
      vim.api.nvim_set_option_value(name, value, { buf = bufnr })
    end,

    current_buf = vim.api.nvim_get_current_buf,
    current_win = vim.api.nvim_get_current_win,
    current_tabpage = vim.api.nvim_get_current_tabpage,
    list_wins = vim.api.nvim_list_wins,
    win_valid = vim.api.nvim_win_is_valid,
    win_buf = vim.api.nvim_win_get_buf,
    set_win_buf = vim.api.nvim_win_set_buf,
    win_cursor = vim.api.nvim_win_get_cursor,
    set_win_cursor = vim.api.nvim_win_set_cursor,
    set_current_win = vim.api.nvim_set_current_win,
    win_tab = vim.api.nvim_win_get_tabpage,
    win_config = vim.api.nvim_win_get_config,
    editor_size = function() return { columns = vim.o.columns, lines = vim.o.lines } end,
    cursor = function(winid)
      local value = vim.api.nvim_win_get_cursor(winid)
      return { line = value[1] - 1, character = value[2] }
    end,
    getpos = function(winid)
      return vim.api.nvim_win_call(winid, function() return vim.fn.getpos(".") end)
    end,
    word_at_cursor = function(bufnr, winid)
      return vim.api.nvim_win_call(winid, function()
        assert(vim.api.nvim_get_current_buf() == bufnr)
        local line = vim.api.nvim_get_current_line()
        local col = vim.api.nvim_win_get_cursor(winid)[2]
        local search = 0
        while search <= #line do
          local match = vim.fn.matchstrpos(line, "\\k\\+", search)
          local text, start_col, end_col = match[1], match[2], match[3]
          if start_col < 0 then
            break
          end
          if start_col <= col and col < end_col then
            return text, start_col, end_col
          end
          search = math.max(end_col, search + 1)
        end
        return "", col, col
      end)
    end,
    word_at = function(lines, line, byte_col)
      local text = lines[line + 1]
      if text == nil or byte_col > #text then return nil end
      local left = text:sub(1, byte_col):match("[%w_]+$") or ""
      local right = text:sub(byte_col + 1):match("^[%w_]+") or ""
      local word = left .. right
      return word ~= "" and word or nil
    end,

    get_clients = vim.lsp.get_clients,
    make_position_params = vim.lsp.util.make_position_params,
    create_augroup = vim.api.nvim_create_augroup,
    delete_augroup = vim.api.nvim_del_augroup_by_id,
    create_autocmd = vim.api.nvim_create_autocmd,
    input = vim.ui.input,
    select = vim.ui.select,
    notify = vim.notify,
    defer = vim.defer_fn,
    timer = function(timeout_ms, on_timeout)
      local handle = assert(vim.uv.new_timer())
      local closed = false
      handle:start(timeout_ms, 0, vim.schedule_wrap(function()
        if not closed then
          on_timeout()
        end
      end))
      return {
        cancel = function()
          if not closed then
            handle:stop()
          end
        end,
        close = function()
          if closed then
            return
          end
          closed = true
          handle:stop()
          handle:close()
        end,
      }
    end,
  }
end

return M
```

The names above are the complete runtime boundary. `locator.lua`, `store.lua`, `sidebar.lua`, `session.lua`, and the native LSP composition use these adapters instead of reading the corresponding globals. Tests replace individual functions on each fresh returned table; do not add an unlisted catch-all `api` or `vim` field.

- [ ] **Step 2: Write project-root, list, and atomic-save tests**

Create `tests/helpers/fake_fs.lua` as an in-memory file map with this exact test-facing contract:

```lua
local fs = FakeFS.new({
  files = {},
  directories = { "/project", "/project/.git", "/project/.voyager/flows" },
  pid = 4321,
  nonces = { "01234567" },
})

fs:runtime()                  -- fresh runtime adapter used by Store.new
fs:fail_next("fs_write", "disk full")
fs:set_short_write(3)         -- at most three bytes per fs_write call
fs:operation_names()          -- ordered names, excluding reads and scans
fs:temp_paths()               -- sorted sibling `.tmp-<pid>-<nonce>` paths
```

The fake assigns integer descriptors, keeps per-descriptor path/mode/content, honors read/write offsets, exposes only configured directories through `fs_stat`/`fs_scandir`, moves bytes only on `fs_rename`, and records `open`, `write`, `fsync`, `close`, `rename`, and `unlink` after applying a configured failure. Its runtime also supplies identity `fs_realpath`, deterministic `now`, `pid`, `random`, `sha256`, `find_root`, and `dirname`; no test may reach the host filesystem.

In `tests/unit/store_spec.lua`, assert the successful write protocol:

```lua
local saved, err = store:save(active_flow)
assert.is_nil(err)
assert.equals(4, saved.revision)
assert.same({ "write", "fsync", "close", "rename" }, fs:operation_names())
assert.equals(Schema.encode(saved), fs.files[store:path_for(saved)])
```

Add these deterministic helpers at the top of `tests/unit/store_spec.lua`:

```lua
local function new_store(fs, schema)
  local runtime = fs:runtime()
  return Store.new({
    runtime = runtime,
    schema = schema or Schema,
    locator = Locator.new(runtime, "/project"),
    flow = Flow,
  })
end

local function active_with_branch(path)
  local flow = Fixtures.new_flow()
  flow:commit_navigation({
    origin_node_id = flow.root.id,
    method = "textDocument/implementation",
    label = "implementations",
    locations = { Fixtures.location(path, 2, "Store.save") },
  })
  return flow
end

local function result_paths(action)
  return vim.tbl_map(function(node)
    return node.location.locator.path
  end, action.results)
end

local function encoded_entry(path, symbol, updated_at)
  local document = Fixtures.document()
  document.root.location.locator.path = path
  document.root.location.symbol = symbol
  document.root_key = Locator.root_key(document.root.location)
  document.name = Locator.flow_name(document.root.location)
  document.flow_id = Locator.flow_id(document.root.location, 8)
  document.updated_at = updated_at
  return "/project/.voyager/flows/" .. document.flow_id .. ".json", Schema.encode(document)
end
```

Then add the following named examples using `FakeFS`:

```lua
it("chooses the fixed project root precedence", function()
  local cases = {
    {
      name = "deepest containing LSP root",
      file = "/repo/apps/api/lua/main.lua",
      clients = { { config = { root_dir = "/repo" } }, { config = { root_dir = "/repo/apps/api" } } },
      git_root = "/repo",
      cwd = "/repo",
      expected = "/repo/apps/api",
    },
    {
      name = "nearest git ancestor",
      file = "/repo/lua/main.lua",
      clients = {},
      git_root = "/repo",
      cwd = "/outside",
      expected = "/repo",
    },
    {
      name = "containing cwd",
      file = "/repo/lua/main.lua",
      clients = {},
      git_root = nil,
      cwd = "/repo",
      expected = "/repo",
    },
    {
      name = "file parent fallback",
      file = "/repo/lua/main.lua",
      clients = {},
      git_root = nil,
      cwd = "/outside",
      expected = "/repo/lua",
    },
  }

  for _, case in ipairs(cases) do
    local fs = FakeFS.new({ files = { [case.file] = "return true\n" } })
    local runtime = fs:runtime()
    runtime.buffer_name = function() return case.file end
    runtime.find_root = function() return case.git_root end
    local store = Store.new({ runtime = runtime, schema = Schema, locator = Locator, flow = Flow })
    assert.equals(case.expected, store:project_root(3, case.clients, case.cwd), case.name)
  end
end)

it("uses only the fixed flows directory and escalates hash collisions", function()
  local fs = FakeFS.new({ directories = { "/project/.voyager/flows" } })
  local flow = Fixtures.document()
  local collision_schema = vim.tbl_extend("force", Schema, {
    decode = function(text)
      if text == "collision-8" then
        return { root_key = flow.root_key:sub(1, 8) .. string.rep("b", 56) }
      elseif text == "collision-16" then
        return { root_key = flow.root_key:sub(1, 16) .. string.rep("c", 48) }
      end
      return Schema.decode(text)
    end,
  })
  local store = new_store(fs, collision_schema)
  assert.equals("/project/.voyager/flows/" .. flow.flow_id .. ".json", store:path_for(flow))

  local path8 = store:path_for(flow)
  fs.files[path8] = "collision-8"
  local path16 = store:path_for(flow)
  assert.matches("%-" .. flow.root_key:sub(1, 16) .. "%.json$", path16)

  fs.files[path16] = "collision-16"
  assert.matches("%-" .. flow.root_key .. "%.json$", store:path_for(flow))
end)

it("returns an empty list for a missing directory and sorts valid entries deterministically", function()
  local empty_entries, empty_warnings = new_store(FakeFS.new()):list("/project")
  assert.same({}, empty_entries)
  assert.same({}, empty_warnings)

  local files = { ["/project/.voyager/flows/corrupt.json"] = "{not-json}\n" }
  for _, entry in ipairs({
    { "lua/zeta.lua", "zeta", "2026-08-01T18:00:00Z" },
    { "lua/b.lua", "alpha", "2026-08-01T19:00:00Z" },
    { "lua/a.lua", "alpha", "2026-08-01T19:00:00Z" },
  }) do
    local path, encoded = encoded_entry(unpack(entry))
    files[path] = encoded
  end
  local fs = FakeFS.new({ directories = { "/project/.voyager/flows" }, files = files })
  local entries, warnings = new_store(fs):list("/project")
  assert.same({ "lua/a.lua", "lua/b.lua", "lua/zeta.lua" }, vim.tbl_map(function(entry)
    return entry.display_path
  end, entries))
  assert.equals(1, #warnings)
  assert.matches("corrupt.json", warnings[1], nil, true)
end)

it("re-reads and recursively merges the latest completed sequential save", function()
  local fs = FakeFS.new({ directories = { "/project/.voyager/flows" } })
  local store = new_store(fs)
  local first = active_with_branch("lua/mysql.lua")
  local second = active_with_branch("lua/memory.lua")
  assert.equals(1, assert(store:save(first)).revision)
  local merged = assert(store:save(second))

  assert.equals(2, merged.revision)
  assert.same({ "lua/mysql.lua", "lua/memory.lua" }, result_paths(merged.root.actions[1]))
end)

it("loops until a short write has persisted every byte", function()
  local fs = FakeFS.new({ directories = { "/project/.voyager/flows" } })
  fs:set_short_write(3)
  local store = new_store(fs)
  local saved = assert(store:save(active_with_branch("lua/mysql.lua")))
  assert.equals(Schema.encode(saved), fs.files[store:path_for(saved)])
  assert.is_true(vim.tbl_count(vim.tbl_filter(function(name) return name == "write" end, fs:operation_names())) > 1)
end)

it("cleans its temp file and preserves disk and journal on every write-stage failure", function()
  for _, operation in ipairs({ "fs_open", "fs_write", "fs_fsync", "fs_close", "fs_rename" }) do
    local existing = Schema.encode(Fixtures.document())
    local path = "/project/.voyager/flows/" .. Fixtures.document().flow_id .. ".json"
    local fs = FakeFS.new({
      directories = { "/project/.voyager/flows" },
      files = { [path] = existing },
    })
    fs:fail_next(operation, "injected " .. operation)
    local active = active_with_branch("lua/mysql.lua")
    local before = active:journal()
    local saved, err = new_store(fs):save(active)

    assert.is_nil(saved, operation)
    assert.matches("injected " .. operation, err, nil, true)
    assert.equals(existing, fs.files[path])
    assert.same({}, fs:temp_paths())
    assert.same(before, active:journal())
    assert.is_true(active:is_dirty())
  end
end)
```

- [ ] **Step 3: Run storage tests red**

Run: `make test-unit TEST_FILE=tests/unit/store_spec.lua`

Expected: FAIL with `module 'voyager.store' not found`.

- [ ] **Step 4: Implement the storage service**

Create `lua/voyager/store.lua` with this interface:

```lua
local store = Store.new({ runtime = runtime, schema = Schema, locator = locator_service, flow = Flow })

store:project_root(bufnr, clients, cwd) --> string
store:path_for(flow) --> absolute_json_path
store:save(flow) --> merged_flow|nil, error_message?
store:list(project_root) --> valid_entries, warnings
store:load(entry_or_path, project_root) --> flow|nil, error_message?
```

`save` must run in one non-yielding callback: re-read the latest file, validate it, call `Flow.merge` when it exists or promote a deep copy of the unsaved flow to revision 1 when it does not, set the injected UTC timestamp, encode, write a unique sibling temp file, loop until all bytes are written, `fsync`, close, and rename. Only then call `flow:mark_saved(merged)`. On any failure, close if open, unlink the temp file, retain the old document, and leave the pre-save dirty journal unchanged.

Use a temp basename of `.<filename>.tmp-<pid>-<nonce_hex>` so two Neovim processes do not share a temp path. Do not coordinate cross-process locks; last completed rename wins as specified.

- [ ] **Step 5: Implement saved-flow scanning and stale metadata**

Scan only `.voyager/flows/*.json`. For each file, call `Schema.decode`, recompute `name`, `root_key`, `flow_id`, and expected filename stem from its root, then either return:

```lua
{
  path = absolute_path,
  name = document.name,
  display_path = document.root.location.locator.path,
  updated_at = document.updated_at,
  document = document,
}
```

or one warning without including the invalid item. Sort `updated_at` descending, then `name`, then `display_path` ascending. Recalculate transient stale flags after load through the locator service; never persist them.

- [ ] **Step 6: Run and commit storage**

Run: `make test-unit TEST_FILE=tests/unit/store_spec.lua`

Run: `make test-unit`

Expected: all PASS.

```bash
git add lua/voyager/runtime.lua lua/voyager/store.lua tests/helpers/fake_fs.lua tests/unit/store_spec.lua
git commit -m "feat: persist project navigation flows"
```

### Task 7: Session-owned buffer-local mappings

**Files:**
- Replace: `lua/voyager/keymaps.lua`
- Create: `tests/unit/keymaps_spec.lua`

- [ ] **Step 1: Write ownership and restoration tests**

Create `tests/unit/keymaps_spec.lua`. Use fresh scratch buffers and assert these independently:

```lua
local Keymaps = require("voyager.keymaps")

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
end)
```

Add these exact ownership cases; keep each in its own `it` block so a failure identifies the lost mapping property:

```lua
it("matches equivalent normalized lhs spellings", function()
  local buffer = vim.api.nvim_create_buf(true, false)
  local original = function() return "original" end
  vim.keymap.set("n", "<C-I>", original, { buffer = buffer, expr = true, replace_keycodes = false })
  local registry = Keymaps.new({ notify = function() end })
  registry:apply_buffer(buffer, 9, { definition = "<Tab>" }, function() return function() end end)
  assert.is_true(registry:is_installed(buffer, "<C-I>"))
  registry:restore_all(9)
  local restored = vim.api.nvim_buf_call(buffer, function()
    return vim.fn.maparg("<C-I>", "n", false, true)
  end)
  assert.equals(original, restored.callback)
  assert.equals(1, restored.expr)
  assert.equals(0, restored.replace_keycodes)
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
  registry:apply_buffer(buffer, 9, { definition = "gd" }, function() return function() end end)
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
end)

it("reveals a global map and never overwrites a newer local owner", function()
  local warnings = {}
  local buffer = vim.api.nvim_create_buf(true, false)
  vim.keymap.set("n", "gd", "global", {})
  local registry = Keymaps.new({ notify = function(message) table.insert(warnings, message) end })
  registry:apply_buffer(buffer, 9, { definition = "gd" }, function() return function() end end)
  registry:restore_all(9)
  assert.equals("global", vim.fn.maparg("gd", "n"))

  registry = Keymaps.new({ notify = function(message) table.insert(warnings, message) end })
  registry:apply_buffer(buffer, 10, { definition = "gd" }, function() return function() end end)
  vim.keymap.set("n", "gd", "new owner", { buffer = buffer })
  registry:restore_all(10)
  registry:restore_all(10)
  assert.equals("new owner", vim.api.nvim_buf_call(buffer, function() return vim.fn.maparg("gd", "n") end))
  assert.equals(1, #warnings)
  vim.keymap.del("n", "gd")
end)
```

Add a final table test which applies the same generation twice, includes a `false` mapping, wipes one mapped buffer, calls `restore_all` twice, and asserts the wrapper factory ran once per enabled `(buffer, normalized_lhs)` and no wiped-buffer mutation was attempted.

- [ ] **Step 2: Run mapping tests red**

Run: `make test-unit TEST_FILE=tests/unit/keymaps_spec.lua`

Expected: FAIL because the prototype module has no constructor.

- [ ] **Step 3: Replace the mapping registry**

Expose only:

```lua
local registry = Keymaps.new({ notify = vim.notify })

registry:apply_buffer(
  bufnr,
  generation,
  config.lsp_keymaps,
  function(action_name)
    return function()
      dispatch(action_name, bufnr, vim.api.nvim_get_current_win())
    end
  end
)

registry:is_installed(bufnr, lhs) --> boolean
registry:restore_all(generation)
```

Implement normalized lookup and reconstruction with these helpers; do not compare the display spelling in `map.lhs` directly:

```lua
local function normalized(lhs)
  return vim.keycode(lhs)
end

local function local_map(bufnr, normalized_lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    local lhs_ok, lhs = pcall(normalized, map.lhs)
    if (lhs_ok and lhs == normalized_lhs)
      or map.lhsraw == normalized_lhs
      or map.lhsrawalt == normalized_lhs
    then
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
```

Key each record by `generation .. NUL .. bufnr .. NUL .. "n" .. NUL .. normalized_lhs`. On first application, snapshot only `local_map(bufnr, normalized_lhs)`, create one wrapper, install it with `vim.keymap.set`, and save both the configured spelling and wrapper identity. On a repeated application with the same key, return without calling the wrapper factory or touching the map. A `false` mapping creates no record.

During `restore_all(generation)`, mark the record restored before any API call. Skip an invalid buffer. Re-read the normalized local map; only when `current.callback == record.wrapper` delete `record.installed_lhs`, then call `restore_map` when a prior local map existed. If no prior local map existed, deletion deliberately reveals the global map. If the wrapper is absent or another callback/RHS owns the normalized LHS, retain the current mapping and issue exactly one warning for that record. `is_installed` normalizes its argument and returns true only for a live, unrestored record whose current callback is the stored wrapper.

- [ ] **Step 4: Verify restoration semantics**

Run: `make test-unit TEST_FILE=tests/unit/keymaps_spec.lua`

Expected: all PASS.

- [ ] **Step 5: Commit mapping ownership**

```bash
git add lua/voyager/keymaps.lua tests/unit/keymaps_spec.lua
git commit -m "feat: preserve session keymaps"
```

### Task 8: Pure sidebar row projection

**Files:**
- Create: `lua/voyager/sidebar.lua`
- Create: `tests/unit/sidebar_spec.lua`

- [ ] **Step 1: Specify stable typed rows**

Create `tests/unit/sidebar_spec.lua` with a branched fixture and assert rows by structure, never by display text lookup:

```lua
local Sidebar = require("voyager.sidebar")
local Fixtures = require("tests.helpers.flow")

it("projects the flow in stable depth-first order", function()
  local flow = Fixtures.branched_flow()
  local rows, header = Sidebar.project(flow, 42, { dirty = true, request_count = 2 })
  assert.same({
    { kind = "location", owner_id = flow.root.id },
    { kind = "action", owner_id = flow.root.actions[1].id },
    { kind = "location", owner_id = flow.root.actions[1].results[1].id },
    { kind = "note", owner_id = flow.root.actions[1].results[1].id },
    { kind = "location", owner_id = flow.root.actions[1].results[2].id },
  }, vim.tbl_map(function(row)
    return { kind = row.kind, owner_id = row.owner_id }
  end, rows))
  assert.matches("%*", header)
  assert.matches("2 requests", header)
end)
```

Add examples for two rows with identical text, current marker, collapsed descendant-current marker, empty action count, stale marker, project/absolute/URI display, note indentation, UTF-8 display-width truncation, and selection fallback to the action that hid a row.

- [ ] **Step 2: Run projection red**

Run: `make test-unit TEST_FILE=tests/unit/sidebar_spec.lua`

Expected: FAIL with `module 'voyager.sidebar' not found`.

- [ ] **Step 3: Implement the pure projection API**

Start `lua/voyager/sidebar.lua` with:

```lua
Sidebar.project(flow, width, status) --> rows, header
Sidebar.selection_index(rows, previous_kind, previous_owner_id, hidden_by_action_id) --> integer
```

Each row must have exactly this semantic shape plus render-only depth/marker fields:

```lua
{
  kind = "location" or "action" or "note",
  owner_id = node_id,
  text = rendered_text,
  depth = integer,
}
```

Traverse root location, its action groups, and each result recursively. Skip only descendants of collapsed actions. Add note rows immediately after their location. Use `vim.fn.strdisplaywidth` while truncating so the result including ellipsis fits `width`; never key `line_to_row` by text.

- [ ] **Step 4: Make every projection example green**

Run: `make test-unit TEST_FILE=tests/unit/sidebar_spec.lua`

Expected: all pure projection examples PASS without creating a window.

- [ ] **Step 5: Commit row projection**

```bash
git add lua/voyager/sidebar.lua tests/unit/sidebar_spec.lua
git commit -m "feat: project flow sidebar rows"
```

### Task 9: One NUI sidebar popup

**Files:**
- Modify: `lua/voyager/sidebar.lua`
- Modify: `tests/unit/sidebar_spec.lua`
- Create: `tests/helpers/fake_popup.lua`

- [ ] **Step 1: Specify geometry without mounting NUI**

Add table-driven tests for `Sidebar.compute_geometry(config, ui_state)`. Cover left/right placement, configured outer width, capping while leaving two source columns, tabline/statusline/cmdheight rows, the editor-grid minimum of 24 columns, minimum height 4, and invalid geometry reasons. The 24-column check applies to the editor grid, not popup content: every already-valid configured width from 20 through 23 must mount when the editor is wide enough.

Use this representative assertion:

```lua
assert.same({ row = 1, col = 78, width = 42, height = 37 }, Sidebar.compute_geometry(
  { side = "right", width = 42, border = "rounded" },
  { columns = 120, lines = 40, tabline_rows = 1, statusline_rows = 1, cmdheight = 1 }
))

for width = 20, 23 do
  local geometry = assert(Sidebar.compute_geometry(
    { side = "right", width = width, border = "rounded" },
    { columns = 30, lines = 12, tabline_rows = 0, statusline_rows = 1, cmdheight = 1 }
  ))
  assert.equals(width, geometry.width)
  assert.equals(30 - width, geometry.col)
end

local geometry, reason = Sidebar.compute_geometry(
  { side = "right", width = 20, border = "rounded" },
  { columns = 23, lines = 12, tabline_rows = 0, statusline_rows = 1, cmdheight = 1 }
)
assert.is_nil(geometry)
assert.equals("editor must be at least 24 columns wide", reason)
```

- [ ] **Step 2: Specify popup ownership and rendering**

Inject `tests/helpers/fake_popup.lua` and test:

```lua
local sidebar = Sidebar.new({
  sidebar = config.sidebar,
  keymaps = config.sidebar_keymaps,
  handlers = handlers,
  popup_factory = fake_popup.factory,
  notify = notify,
})

assert.is_true(sidebar:mount({ tabpage = 1, focus = false }))
assert.is_true(sidebar:is_mounted())
sidebar:render(flow, { dirty = false, request_count = 0 })
assert.equals(flow.root.id, sidebar:selected_row().owner_id)
assert.is_true(sidebar:owns_window(fake_popup.winid))
```

Add assertions that mount creates one `nofile` scratch buffer, never changes a source buffer's options, `render` never changes focus, selection survives rerender, collapsing falls back correctly, invalid remount hides without ending the session, valid remount returns without entering, and owned/external close signals differ.

Add the real-NUI safety example now, before any constructor or mount implementation:

```lua
it("mounts only a scratch popup and preserves the source window", function()
  local source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(source, vim.fn.tempname() .. ".lua")
  vim.api.nvim_set_current_buf(source)
  vim.bo[source].modifiable = true
  vim.bo[source].readonly = false
  local source_win = vim.api.nvim_get_current_win()
  local windows_before = #vim.api.nvim_list_wins()
  local noop = function() end

  local sidebar = Sidebar.new({
    sidebar = { side = "right", width = 20, border = "rounded" },
    keymaps = {
      jump_or_toggle = false,
      note = false,
      save = false,
      load = false,
      toggle = false,
      close = false,
    },
    handlers = {
      activate = noop,
      note = noop,
      save = noop,
      load = noop,
      toggle = noop,
      close = noop,
      external_close = noop,
    },
    notify = noop,
  })

  assert.is_true(sidebar:mount({ tabpage = vim.api.nvim_get_current_tabpage(), focus = false }))
  assert.equals(source_win, vim.api.nvim_get_current_win())
  assert.equals(source, vim.api.nvim_win_get_buf(source_win))
  assert.is_true(vim.bo[source].modifiable)
  assert.is_false(vim.bo[source].readonly)
  assert.equals(windows_before + 1, #vim.api.nvim_list_wins())

  local popup_win
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if sidebar:owns_window(winid) then
      popup_win = winid
    end
  end
  assert.is_not_nil(popup_win)
  assert.equals("nofile", vim.bo[vim.api.nvim_win_get_buf(popup_win)].buftype)

  sidebar:unmount({ owned = true })
  assert.equals(windows_before, #vim.api.nvim_list_wins())
  vim.api.nvim_buf_delete(source, { force = true })
end)
```

- [ ] **Step 3: Run popup tests red**

Run: `make test-unit TEST_FILE=tests/unit/sidebar_spec.lua`

Expected: FAIL on absent `compute_geometry`/constructor methods, including the real-NUI example, while projection tests stay green.

- [ ] **Step 4: Implement the popup contract**

Add:

```lua
Sidebar.new(opts) --> sidebar
sidebar:mount({ tabpage = integer, focus = boolean }) --> true|nil, reason?
sidebar:remount({ tabpage = integer, focus = boolean }) --> true|nil, reason?
sidebar:unmount({ owned = boolean })
sidebar:render(flow, { dirty = boolean, request_count = integer })
sidebar:focus() --> boolean
sidebar:is_mounted() --> boolean
sidebar:owns_window(winid) --> boolean
sidebar:selected_row() --> row|nil
```

Treat computed width/height as the popup's outer dimensions; subtract the two border cells on each bordered axis when passing NUI its content size. Construct one `nui.popup` with `relative = "editor"`, the computed row/column/size, configured border, `enter = false`, and a fresh `nofile` buffer. Keep `line_to_row` as a numeric array. Bind all configured sidebar keys only in this buffer and delegate typed rows to `activate`, `note`, `toggle`, `save`, `load`, and `close` handlers. The popup's external `WinClosed` callback invokes `handlers.external_close`; an internal remount/unmount guard suppresses that callback.

- [ ] **Step 5: Run fake and real popup examples green**

Run: `make test-unit TEST_FILE=tests/unit/sidebar_spec.lua`

Expected: all PASS and no leaked windows.

- [ ] **Step 6: Commit the popup**

```bash
git add lua/voyager/sidebar.lua tests/unit/sidebar_spec.lua tests/helpers/fake_popup.lua
git commit -m "feat: mount the flow sidebar"
```

### Task 10: LSP location normalization

**Files:**
- Create: `lua/voyager/lsp/normalize.lua`
- Create: `tests/unit/lsp_normalize_spec.lua`
- Create: `tests/helpers/fake_lsp_client.lua`

- [ ] **Step 1: Write normalization examples for every wire shape**

Create `tests/unit/lsp_normalize_spec.lua`. Build client snapshots with `id`, `name`, and `offset_encoding`, and test singleton `Location`, a list, and `LocationLink`. The first exact assertion is:

```lua
local presentation, unique, failures = normalizer:locations({
  {
    client = { id = 7, name = "utf16", offset_encoding = "utf-16" },
    result = {
      targetUri = "file:///project/lua/auth.lua",
      targetRange = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 4 } },
      targetSelectionRange = { start = { line = 0, character = 1 }, ["end"] = { line = 0, character = 3 } },
    },
  },
})

assert.same({ start = { line = 0, character = 1 }, ["end"] = { line = 0, character = 5 } }, unique[1].range)
assert.equals(unique[1].identity, presentation[1].identity)
assert.equals(7, presentation[1].client_id)
assert.same({}, failures)
```

The fake source line is `a😀b`. Add these assertions after constructing a locator with `tests/helpers/buffer.lua`; use response input deliberately ordered as `zeta/9`, `alpha/8`, `alpha/2`:

```lua
local presentation, unique, failures, summary = normalizer:locations(responses)
assert.same({ 2, 8, 9 }, vim.tbl_map(function(item) return item.client_id end, presentation))
assert.same({ 1, 1, 1 }, vim.tbl_map(function(item) return item.response_index end, presentation))
assert.equals(3, #presentation) -- raw multiplicity survives
assert.equals(1, #unique)       -- one canonical flow identity
assert.equals("auth.lua:1", unique[1].symbol)
assert.equals("a😀b", unique[1].context)
assert.same({ filename = "/project/lua/auth.lua", lnum = 1, col = 2, end_lnum = 1, end_col = 6 }, {
  filename = presentation[1].list_item.filename,
  lnum = presentation[1].list_item.lnum,
  col = presentation[1].list_item.col,
  end_lnum = presentation[1].list_item.end_lnum,
  end_col = presentation[1].list_item.end_col,
})
assert.same({}, failures)
assert.same({ usable_response_count = 3, empty_response_count = 0, invalid_response_count = 0 }, summary)
```

Add one named example for each row of this table; assert `env.buffers` stays empty for the disk row and assert the exact failure object for the invalid rows:

| Input | Expected |
| --- | --- |
| loaded modified `/project/lua/auth.lua` plus different disk text | loaded lines determine bytes, symbol, and context |
| unloaded file target | `read_file` supplies text and `list_item.filename`; no buffer is added |
| `LocationLink` | `targetSelectionRange`, then `targetRange` fallback |
| negative, past-EOL, split-code-unit, or reversed range | item omitted and one `normalization` failure |
| unresolved `jdt:` URI | item omitted and one `normalization` failure |
| one valid and one invalid raw item | valid item retained and one summarized failure with `invalid_item_count = 1` |
| non-empty response with every item invalid | `invalid_response_count = 1`, `usable_response_count = 0` |
| `nil` or `{}` successful result | no items/failures, `empty_response_count = 1`, `usable_response_count = 1` |

- [ ] **Step 2: Run normalization red**

Run: `make test-unit TEST_FILE=tests/unit/lsp_normalize_spec.lua`

Expected: FAIL with `module 'voyager.lsp.normalize' not found`.

- [ ] **Step 3: Implement normalized items and deduplication**

Create `lua/voyager/lsp/normalize.lua`:

```lua
local normalizer = Normalize.new({ locator = locator_service })

normalizer:locations(ordered_client_responses)
  --> presentation_items, unique_locations, failures, summary

normalizer:call_sites(direction, client_snapshot, prepared_item, calls)
  --> presentation_items, unique_locations, failures, summary
```

Use these exact shared records:

```lua
---@class VoyagerClientSnapshot
---@field id integer
---@field name string
---@field offset_encoding "utf-8"|"utf-16"|"utf-32"
---@field client vim.lsp.Client

---@class VoyagerStageResponse
---@field client VoyagerClientSnapshot
---@field result any

---@class VoyagerFailure
---@field kind "setup"|"protocol"|"timeout"|"normalization"|"unsupported"|"cancelled"
---@field client_id integer?
---@field client_name string?
---@field response_index integer?
---@field invalid_item_count integer?
---@field message string

---@class VoyagerNormalizationSummary
---@field usable_response_count integer -- response had >=1 valid item or was truly empty
---@field empty_response_count integer
---@field invalid_response_count integer -- non-empty response with zero valid items
```

Every presentation item must be:

```lua
{
  identity = Locator.location_key(canonical_location),
  location = canonical_location,
  raw = original_protocol_value,
  client_id = client.id,
  client_name = client.name,
  offset_encoding = client.offset_encoding,
  response_index = integer,
  range_index = integer_or_nil,
  list_item = {
    bufnr = loaded_target_bufnr_or_nil,
    filename = unloaded_file_absolute_path_or_nil,
    lnum = canonical_start_line + 1,
    col = canonical_start_byte + 1,
    end_lnum = canonical_end_line + 1,
    end_col = canonical_end_byte + 1,
    text = exact_source_line,
  },
}
```

Sort a defensive copy of responses by `client.name`, then `client.id`; preserve each response's server order. For `LocationLink`, use `targetSelectionRange` and fall back to `targetRange`; for `Location`, use `range`. Convert each range using the responding client's encoding and the locator service's loaded-buffer-first source. Call `locator:metadata(locator, lines, canonical_range, nil)` and create this full location before calculating identity:

```lua
local location = {
  locator = canonical_locator,
  range = canonical_range,
  symbol = symbol,
  context = context ~= "" and context or nil,
}
location.identity = Locator.location_key(location)
```

Build `list_item` directly from canonical bytes and `locator:list_target`; do not call `vim.lsp.util.locations_to_items`, because that creates a destination buffer during normalization. Build `unique_locations` by first occurrence of `identity`; never deduplicate `presentation_items`. Deep-copy the unique location so later presentation tagging cannot mutate flow input.

Count a response as truly empty only when its protocol result is `nil` or an empty list. For every non-empty response, count invalid raw items; if any are invalid, append one summarized `VoyagerFailure` with `kind = "normalization"`, the client fields, sorted `response_index`, `invalid_item_count`, and a stable message. A response with at least one valid item remains usable; a non-empty response with no valid item increments only `invalid_response_count`.

- [ ] **Step 4: Implement both call-site conversions**

For incoming calls, pair each `call.fromRanges` range with `call.from.uri` and pass `call.from.name` as the preferred symbol. For outgoing calls, pair each `call.fromRanges` range with `prepared_item.item.uri` and pass `call.to.name` as the preferred symbol. Retain the entire original call object in `raw`, use the one-based call index as `response_index`, and retain the one-based `range_index` so multiple call sites are distinct presentation items. Apply the same invalid-item summary rules as `locations`; an empty `calls` list is a true empty success.

Add both exact direction assertions:

```lua
local incoming = normalizer:call_sites("incoming", client, prepared, {
  { from = caller, fromRanges = { caller.selectionRange, caller.range } },
})
assert.same(locator:from_uri(caller.uri), incoming[1].location.locator)
assert.equals(caller.name, incoming[1].location.symbol)
assert.same({ 1, 2 }, { incoming[1].range_index, incoming[2].range_index })

local outgoing = normalizer:call_sites("outgoing", client, prepared, {
  { to = callee, fromRanges = { prepared.item.selectionRange } },
})
assert.same(locator:from_uri(prepared.item.uri), outgoing[1].location.locator)
assert.equals(callee.name, outgoing[1].location.symbol)
```

- [ ] **Step 5: Run and commit normalization**

Run: `make test-unit TEST_FILE=tests/unit/lsp_normalize_spec.lua`

Expected: all PASS.

```bash
git add lua/voyager/lsp/normalize.lua tests/unit/lsp_normalize_spec.lua tests/helpers/fake_lsp_client.lua
git commit -m "feat: normalize LSP locations"
```

### Task 11: Per-client request groups and standard LSP façade

**Files:**
- Create: `lua/voyager/lsp/request_group.lua`
- Create: `lua/voyager/lsp.lua`
- Create: `tests/helpers/fake_timer.lua`
- Create: `tests/unit/request_group_spec.lua`
- Create: `tests/unit/lsp_spec.lua`

- [ ] **Step 1: Specify exactly-once request-group behavior**

Create `tests/unit/request_group_spec.lua` with fake clients whose `request` callbacks can run before `request` returns. Assert:

```lua
local completions = {}
local handle = RequestGroup.start({
  clients = { sync_client, async_client },
  method = "textDocument/definition",
  bufnr = 3,
  timeout_ms = 1000,
  make_params = function(snapshot)
    return { client = snapshot.id }
  end,
  timer = fake_timer,
  on_complete = function(outcome)
    table.insert(completions, outcome)
  end,
})

assert.equals(0, #completions)
async_client:reply(nil, {})
assert.equals(1, #completions)
assert.is_true(handle:is_done())
sync_client:reply_late(nil, {})
assert.equals(1, #completions)
assert.same({ "sync", "async" }, vim.tbl_map(function(response)
  return response.client.name
end, completions[1].responses))
assert.same({}, completions[1].failures)
assert.equals("success", completions[1].status)
```

The fake `client:request` must itself return Neovim's two values, `(boolean, integer?)`; a synchronous fake invokes its callback before returning `(true, request_id)`. Add a table test with these exact outcomes:

| Exit | Responses | Failure kinds | Status | Extra assertion |
| --- | ---: | --- | --- | --- |
| all replies, out of order | 2 | none | `success` | output sorted by name/ID |
| `(false, nil)` or `(true, nil)` dispatch | 0 | `setup` | `error` | no cancellation attempted |
| protocol error from every client | 0 | `protocol` | `error` | error messages retained |
| one success plus protocol error | 1 | `protocol` | `partial` | success retained |
| one success plus hung client | 1 | `timeout` | `partial` | hung request ID cancelled |
| every pending client times out | 0 | `timeout` only | `timeout` | all pending IDs cancelled |
| timeout plus any non-timeout total failure | 0 | mixed | `error` | deterministic precedence |
| `handle:cancel("close")` | 0 | `cancelled` | `cancelled` | pending IDs cancelled |

For every row, assert the timer's `cancel` and `close` each run once, `on_complete` runs once, and a late response changes nothing. Also test a thrown `make_params`/`client:request` as `setup` failure and a synchronous response followed by a returned request ID: the already-settled slot must never retain or cancel that ID.

- [ ] **Step 2: Run request-group tests red**

Run: `make test-unit TEST_FILE=tests/unit/request_group_spec.lua`

Expected: FAIL with missing module.

- [ ] **Step 3: Implement the dispatch barrier**

Create `lua/voyager/lsp/request_group.lua` with:

```lua
RequestGroup.start({
  clients = client_snapshots,
  method = method,
  bufnr = bufnr,
  timeout_ms = timeout_ms,
  make_params = function(snapshot) return params end,
  timer = cancellable_timer_factory,
  on_complete = function(stage_outcome) end,
}) --> handle
```

Return this exact stage record:

```lua
---@class VoyagerStageOutcome
---@field status "success"|"partial"|"error"|"timeout"|"cancelled"
---@field responses VoyagerStageResponse[]
---@field failures VoyagerFailure[]
```

Before the first request, sort client snapshots by name/ID, allocate every slot, start the timer, and set `dispatching = true`. Dispatch exactly as Neovim 0.12.4 requires:

```lua
local callback = function(err, result)
  settle_response(slot, err, result)
  if not dispatching then
    maybe_finalize()
  end
end

local call_ok, dispatched, request_id = pcall(function()
  local params = make_params(snapshot)
  return snapshot.client:request(method, params, callback, bufnr)
end)
if not call_ok or dispatched ~= true or request_id == nil then
  settle_failure(slot, "setup", call_ok and "client rejected request" or tostring(dispatched))
elseif slot.pending then
  slot.request_id = request_id
end
```

The callback turns non-nil `err` into a `protocol` failure and otherwise appends `{ client = snapshot, result = result }`, including `nil`/empty successful results. Release the barrier after the final dispatch and call `maybe_finalize()` once. A deadline settles only pending slots as `timeout` and best-effort calls `client:cancel_request(request_id)`. `handle:cancel(reason)` does the same with `cancelled` and finalizes immediately. Finalization marks the group done before external cleanup/callbacks, cancels and closes the timer once, and sorts failures by client name/ID. Status is `success` with no failures, `partial` with responses plus failures, `timeout` only with zero responses and exclusively timeout failures, `cancelled` for explicit cancellation, and `error` for every other zero-response failure combination.

- [ ] **Step 4: Specify standard façade outcomes**

Create `tests/unit/lsp_spec.lua` around:

```lua
local service = require("voyager.lsp").new(deps)
local handle = service:start("references", {
  generation = 4,
  request_token = 12,
  origin_node_id = "loc-root",
  bufnr = 3,
  winid = 8,
  project_root = "/project",
  timeout_ms = 1000,
}, function(outcome)
  completed = outcome
end)
```

Assert client discovery uses `vim.lsp.get_clients({ bufnr = 3, method = "textDocument/references" })`; each returned client is frozen into `{ id, name, offset_encoding, client }`; params are built separately with each encoding; and only references adds `{ context = { includeDeclaration = true } }` to that client's position params. Assert the complete outcome table:

| Transport/normalization result | Facade status | Commit-capable |
| --- | --- | --- |
| valid locations, no failures | `success` | yes |
| true empty, no failures | `empty` | yes |
| at least one usable response plus any failure | `partial` | yes, even when usable response is empty |
| zero usable responses and all failures are `timeout` | `timeout` | no |
| zero usable responses and any failure is not `timeout` | `error` | no |
| no supporting clients | `unsupported` | no dispatch |
| explicit handle cancellation | `cancelled` | no |

For each row, assert `on_complete` exactly once, the preserved action `method`/`label`/`origin_node_id`, raw item count, unique location count, and exact ordered `VoyagerFailure` records. Assert a standard handle's `supersede_interactive()` is a no-op so an older standard request can still finish for silent recording.

- [ ] **Step 5: Implement the standard-action façade**

Expose:

```lua
---@class VoyagerLspHandle
---@field cancel fun(self, reason:string)
---@field supersede_interactive fun(self)
---@field is_done fun(self):boolean

local service = Lsp.new({
  actions = Actions,
  normalizer = normalizer,
  request_group = RequestGroup,
  get_clients = vim.lsp.get_clients,
  make_position_params = vim.lsp.util.make_position_params,
  timer = timer_factory,
  select = vim.ui.select,
})

service:start(action_name, context, on_complete) --> VoyagerLspHandle
```

Use this exact logical outcome for standard and call-hierarchy paths:

```lua
---@class VoyagerLspOutcome
---@field status "success"|"partial"|"empty"|"error"|"timeout"|"unsupported"|"cancelled"|"superseded"
---@field action table -- immutable deep copy of the Task 2 action record
---@field method string
---@field label string
---@field origin_node_id string
---@field items VoyagerPresentationItem[]
---@field locations VoyagerLocation[]
---@field failures VoyagerFailure[]
```

`on_complete` may run synchronously and must run exactly once. For standard actions, call `normalizer:locations(stage.responses)`, append normalization failures to transport failures, and classify with the table above using `summary.usable_response_count`. A failure summary is always sorted by client name/ID, then response index/kind. Never mutate flow or UI here.

- [ ] **Step 6: Run and commit transport**

Run: `make test-unit TEST_FILE=tests/unit/request_group_spec.lua`

Run: `make test-unit TEST_FILE=tests/unit/lsp_spec.lua`

Run: `make test-unit`

Expected: all PASS.

```bash
git add lua/voyager/lsp/request_group.lua lua/voyager/lsp.lua tests/helpers/fake_timer.lua tests/unit/request_group_spec.lua tests/unit/lsp_spec.lua
git commit -m "feat: aggregate LSP client requests"
```

### Task 12: Two-stage call hierarchy

**Files:**
- Create: `lua/voyager/lsp/call_hierarchy.lua`
- Modify: `lua/voyager/lsp.lua`
- Create: `tests/unit/call_hierarchy_spec.lua`

- [ ] **Step 1: Write same-client prepare/follow-up tests**

Create `tests/unit/call_hierarchy_spec.lua` with two client snapshots. Assert that the selected tuple retains `(client_id, item, response_index)` and only its originating client receives `callHierarchy/incomingCalls` or `callHierarchy/outgoingCalls`.

Use this observable sequence:

```lua
local handle = CallHierarchy.start(opts)
assert.same({ "textDocument/prepareCallHierarchy" }, client_a.methods)
client_a:reply_prepare(nil, { prepared_a })
client_b:reply_prepare(nil, {})
assert.same({ "textDocument/prepareCallHierarchy", "callHierarchy/incomingCalls" }, client_a.methods)
assert.same({ "textDocument/prepareCallHierarchy" }, client_b.methods)
```

Add exact cases for one prepared item, multiple items through `vim.ui.select`, picker cancellation, prepare empty success, follow-up empty success, unsupported prepare, unsupported follow-up, and a fresh deadline object per network stage. Advance the fake clock while a picker is open and assert no timer exists; after selection assert the follow-up timer starts with the full `context.timeout_ms`. This unit owns no session counter: assert one and only one `on_complete` call for every exit; Task 15 asserts request-counter settlement.

- [ ] **Step 2: Specify supersession and late-picker safety**

Use `context.request_token = 12` and an `owns_presentation(token)` fake that records and compares the argument. Assert every check receives `12`. Add these sequences:

```lua
-- Ownership is lost while prepare is pending. One result may continue silently.
owns = false
client_a:reply_prepare(nil, { prepared_a })
assert.equals("callHierarchy/incomingCalls", client_a.methods[2])

-- Multiple results need UI, so lost ownership finalizes without opening a picker.
owns = false
client_a:reply_prepare(nil, { prepared_a, prepared_b })
assert.equals("superseded", completed.status)
assert.equals(0, #select_calls)

-- An already-open picker is invalidated and settled immediately.
owns = true
client_a:reply_prepare(nil, { prepared_a, prepared_b })
handle:supersede_interactive()
assert.equals("superseded", completed.status)
select_calls[1].callback(prepared_a)
assert.equals(1, #completions)
assert.equals(1, #client_a.methods) -- no follow-up after the stale callback
```

- [ ] **Step 3: Run call hierarchy red**

Run: `make test-unit TEST_FILE=tests/unit/call_hierarchy_spec.lua`

Expected: FAIL with missing module.

- [ ] **Step 4: Implement the hierarchy state machine**

Create `lua/voyager/lsp/call_hierarchy.lua`:

```lua
CallHierarchy.start({
  action = action_spec,
  context = context,
  clients = client_snapshots,
  request_stage = RequestGroup.start,
  normalizer = normalizer,
  select = injected_ui_select,
  owns_presentation = function(request_token) return boolean end,
  on_complete = done,
}) --> VoyagerLspHandle
```

Discover prepare clients with `{ bufnr = context.bufnr, method = action.prepare_method }`; zero clients completes once as `unsupported`. Flatten successful prepare results in stage response order and retain this immutable tuple:

```lua
{
  client_id = response.client.id,
  client = response.client,
  item = vim.deepcopy(item),
  response_index = flattened_one_based_index,
}
```

Carry prepare failures into the final action outcome. With zero prepared items, return `empty`/`partial` only if the prepare stage had a usable true-empty response; otherwise preserve its `error`/`timeout`. Continue directly for one tuple even when `owns_presentation(context.request_token)` is false. For multiple tuples, check ownership before opening `select`; if false, complete `superseded`. A picker has a monotonically increasing local token but no timer. Its callback first checks `not done`, the local token, and `owns_presentation(context.request_token)`; `nil` selection returns `cancelled`, and stale ownership returns `superseded`.

Before follow-up, call `selected.client.client:supports_method(action.method, context.bufnr)`. A false result completes `unsupported` without dispatch. Otherwise start a new request group with only `selected.client`, a newly created full deadline, and params `{ item = vim.deepcopy(selected.item) }`. Normalize its result with `normalizer:call_sites(action.direction, selected.client, selected, calls)`. A true empty follow-up produces `empty` (or `partial` when carried failures exist); valid sites produce `success`/`partial`; total failures preserve the deterministic Task 11 precedence.

Own one `finish(outcome)` guard which sets `done = true` before invalidating picker/stage state and invoking `on_complete`. `handle:cancel(reason)` invalidates the picker, cancels the active request group, and finishes `cancelled` once. `handle:supersede_interactive()` only settles an open/required multi-item picker as `superseded`; it is a no-op for prepare/follow-up network stages and for the single-item path, which may finish silently.

- [ ] **Step 5: Route call actions through the façade**

In `lua/voyager/lsp.lua`, dispatch `incoming_calls` and `outgoing_calls` to `CallHierarchy.start`; leave the five standard action paths unchanged. Pass `context.request_token` unchanged, use the same logical-outcome record, and keep the one façade-level exactly-once guard around the returned handle and callback.

- [ ] **Step 6: Run and commit call hierarchy**

Run: `make test-unit TEST_FILE=tests/unit/call_hierarchy_spec.lua`

Run: `make test-unit`

Expected: all PASS.

```bash
git add lua/voyager/lsp/call_hierarchy.lua lua/voyager/lsp.lua tests/unit/call_hierarchy_spec.lua
git commit -m "feat: implement call hierarchy flow"
```

### Task 13: Native presentation and selection tracking

**Files:**
- Create: `lua/voyager/lsp/presentation.lua`
- Create: `tests/unit/presentation_spec.lua`

- [ ] **Step 1: Specify native single-jump behavior**

Create `tests/unit/presentation_spec.lua`. Build a real source window/buffer and target buffer, then pass this invocation-time context and tagged item:

```lua
local context = {
  generation = 4,
  request_token = 12,
  bufnr = source_buf,
  winid = source_win,
  from = { source_buf, 3, 7, 0 },
  tagname = "authorize",
  project_root = "/project",
}
local item = {
  identity = '["project","lua/auth.lua",0,1,0,5]',
  node_id = "loc-result",
  location = result_location,
  raw = raw_location_link,
  list_item = { bufnr = target_buf, lnum = 1, col = 2, end_lnum = 1, end_col = 6, text = "a😀b" },
}

presenter:present(context, { item }, Actions.get("definition"))
```

Assert the chosen jump window's jumplist records its prior cursor, its tagstack top is exactly `{ tagname = "authorize", from = context.from }`, `reuse_win` selects an already-visible target when configured, the destination buffer becomes listed, cursor becomes `{ 1, 1 }` (one-based row/zero-based byte column), folds open, and `set_current("loc-result")` runs exactly once after a successful jump. Mutate the live source cursor/tag word before `present` and assert the stored tag still uses `context.from`/`context.tagname`, proving completion-time editor state is never recaptured. When `choose_window` returns nil, assert no jumplist/tagstack/cursor/current mutation.

- [ ] **Step 2: Specify list behavior from raw multiplicity**

Add cases proving two duplicate raw targets open a two-item list even though both tags map to one flow node; one reference opens a list; `loclist` uses `context.winid` as owner (or the chosen eligible fallback when it is invalid); quickfix uses `setqflist`; and call items retain the original call object. Every normalized item already carries its original protocol object in `raw`; the presenter deep-copies that object into list `user_data` and adds:

```lua
user_data.voyager = {
  generation = generation,
  request_token = request_token,
  node_id = node_id,
}
```

Selecting an active tagged list item changes current only when list ID/index and entered cursor match. Unrelated movement to the same coordinate does nothing.

Assert the quickfix/loclist title and `context = { bufnr = context.bufnr, method = action.method }` match `vim.lsp.LocationOpts.OnList`. After opening, capture the concrete list ID and index in the observer. Change each of ID, index, nested tag, generation, request token, node lookup, and entered cursor independently and assert no `set_current`; only the exact active tuple may select once.

- [ ] **Step 3: Specify custom `on_list` ownership**

Capture `select` from `navigation.on_list(list, select)`. Assert `on_list` receives every non-empty set, including one definition, and completely replaces `reuse_win`/quickfix/loclist behavior. A valid tagged item jumps/selects, an untagged item is rejected, navigation without `select` leaves logical current unchanged, and an old callback becomes a no-op after any newer default/custom presentation, load, or close.

- [ ] **Step 4: Run presentation red**

Run: `make test-unit TEST_FILE=tests/unit/presentation_spec.lua`

Expected: FAIL with missing module.

- [ ] **Step 5: Implement the presenter**

Create `lua/voyager/lsp/presentation.lua` with:

```lua
local presenter = Presentation.new({
  navigation = config.navigation,
  resolve_node = function(node_id) return flow:location(node_id) end,
  choose_window = session_choose_jump_window,
  set_current = session_set_current,
  notify = vim.notify,
})

presenter:present(context, tagged_items, action_spec)
presenter:on_cursor_moved(winid)
presenter:invalidate()
```

`context` is immutable invocation data and must contain `generation`, `request_token`, `bufnr`, `winid`, `from`, `tagname`, and `project_root`. `tagged_items` are Task 10 presentation items plus a required `node_id`; never infer the node from coordinates.

First deep-copy every `list_item`, set `user_data = vim.deepcopy(item.raw)`, and then set `user_data.voyager = { generation = context.generation, request_token = context.request_token, node_id = item.node_id }`. This preserves the complete original `Location`, `LocationLink`, or call object beside the Voyager tag without mutating the protocol value retained in `item.raw`.

If `navigation.on_list` is callable and the set is non-empty, call it immediately as `on_list({ title = action.label, items = list_items, context = { bufnr = context.bufnr, method = action.method } }, select)` and perform no default presentation. Otherwise copy Neovim 0.12.4's `get_locations` semantics through the session's eligible-window chooser: execute `normal! m'` in the chosen jump window, push `{ tagname = context.tagname, from = vim.deepcopy(context.from) }` with `vim.fn.settagstack(winid, { items = tagstack }, "t")`, optionally reuse an existing target window, list the destination buffer, call `nvim_win_set_buf`, set the byte cursor, and run `normal! zv` in that window. References and both call actions always list non-empty results; other actions jump only for raw count one. A call-hierarchy empty result opens no list.

For a list, call `setqflist` plus `botright copen`, or `setloclist(owner_winid, ...)` plus `lopen`, then record `{ kind, owner_winid, list_id, index, generation, request_token, presentation_token }`. `on_cursor_moved` resolves the active list by that exact ID/index, validates the nested tag and `resolve_node(node_id)`, and compares the entered buffer/one-based row/zero-based byte column with the canonical node before `set_current`. Do not select merely because an unrelated cursor happens to share coordinates.

Every call to `present` replaces one active presentation token. A custom `select` validates session generation, that active token, the nested tag, and current node lookup before jumping. `invalidate` clears observers and invalidates all captured callbacks.

- [ ] **Step 6: Run and commit presentation**

Run: `make test-unit TEST_FILE=tests/unit/presentation_spec.lua`

Run: `make test-unit`

Expected: all PASS.

```bash
git add lua/voyager/lsp/presentation.lua tests/unit/presentation_spec.lua
git commit -m "feat: present recorded LSP results"
```

### Task 14: Session open, focus, remount, and teardown lifecycle

**Files:**
- Create: `lua/voyager/session.lua`
- Create: `tests/helpers/fake_session_deps.lua`
- Create: `tests/unit/session_spec.lua`

- [ ] **Step 1: Specify atomic session opening**

Create `tests/unit/session_spec.lua` using factories for sidebar, keymaps, flow, store, LSP, presenter, locator, and UI. Assert invalid unnamed/special origins and invalid initial geometry create no session, mappings, or autocmds. Assert a valid normal named buffer:

```lua
local session = Session.new(deps)
assert.is_true(session:open())
assert.is_true(session:is_active())
assert.equals("active", session:state().phase)
assert.equals(origin_win, session:state().source_windows[1])
assert.equals(root_id, session:state().flow.current_node_id)
assert.is_false(session:state().flow:is_dirty())
assert.same({ origin_buf }, keymaps.applied_buffers)
assert.is_false(sidebar.mount_calls[1].focus)
```

Add cases for named unsaved buffers, entropy failure, repeated `open` focusing the same flow, `focus` remounting a hidden valid popup, and invalid focus geometry warning without session loss.

- [ ] **Step 2: Run lifecycle red**

Run: `make test-unit TEST_FILE=tests/unit/session_spec.lua`

Expected: FAIL with `module 'voyager.session' not found`.

- [ ] **Step 3: Implement construction and opening**

Create `lua/voyager/session.lua` with:

```lua
local session = Session.new({
  config_provider = function() return immutable_config_snapshot end,
  runtime = runtime,
  sidebar_factory = sidebar_factory,
  keymaps_factory = keymaps_factory,
  flow = Flow,
  locator_factory = function(project_root, resolve_uri) return locator_service end,
  store_factory = function(locator) return store end,
  lsp_factory = function(locator, config) return lsp_service end,
  presenter_factory = function(config, callbacks) return presenter end,
  ui = { input = runtime.input, select = runtime.select, notify = runtime.notify },
})

session:open()
session:focus()
session:is_active() --> boolean
session:state() --> read-only test snapshot
```

Internal state must contain `phase`, `generation`, `flow`, `project_root`, `request_count`, request handles, interaction tokens, presentation/current-claim tokens, source-window recency, autocmd group, sidebar, mapping registry, and the per-session locator/store/LSP/presenter services. `open` snapshots configuration, determines the project root, then calls the four service factories with that fixed root/configuration. Validate geometry and capture root/entropy into local variables first; assign active state only after sidebar mount succeeds.

Factor the construction portion into a side-effect-free `Session:_stage_state(opts)` helper shared by `open` and Task 16's load transaction. It returns a complete state table with fresh sidebar, keymaps, LSP, and presenter services, but must not assign `self._state`, mount, register autocmds, install mappings, render, jump, cancel an old service, or otherwise touch editor/session state. Lifecycle helpers that register, map, render, or jump take the staged state explicitly so no callback can observe a half-installed state.

- [ ] **Step 4: Specify tab/resize/window lifecycle**

Add tests for `TabEnter` guarded remount without focus, invalid `VimResized` hiding the popup, later valid resize remounting, source `WinClosed` candidate eviction, clean-flow external popup `WinClosed`, and internal remount suppression. Dirty popup-close cancellation/remount is added with the decision state machine in Task 16.

The jump-window chooser must prefer the most recent valid eligible window, then a valid non-floating normal window in the active tab, then warn and return nil without creating a split.

- [ ] **Step 5: Specify idempotent clean close and shutdown**

Assert clean `close()` and `shutdown()` cancel every request, invalidate presenter/input/select/decision tokens, delete the session autocmd group, close only Voyager windows, restore owned mappings once, and increment generation. `shutdown()` never prompts or saves. Final focus moves only when focus was in Voyager-owned UI; otherwise the user's current window is retained.

- [ ] **Step 6: Implement lifecycle autocmds and teardown**

Register one session augroup for `BufEnter`, `LspAttach`, `WinEnter`, `WinClosed`, `TabEnter`, `VimResized`, and `VimLeavePre`. Session callbacks must validate generation before using state. Eligible buffers are listed normal files under the fixed project root or locations already in the flow; exclude Voyager/prompt/terminal/special buffers.

Implement:

```lua
session:close(source)
session:shutdown()
session:choose_jump_window() --> winid|nil
```

Teardown must mark `phase = "closing"` and invalidate generation before invoking external cleanup, then end at `closed`. Repeated teardown is a silent no-op.

- [ ] **Step 7: Specify native composition before the public façade uses it**

Add an injectable native-factory test to `tests/unit/session_spec.lua`:

```lua
it("wires native sidebar and presenter callbacks back to one controller", function()
  local deps = FakeSessionDeps.new()
  local captured = {}
  local factories = {
    flow = deps.flow_module,
    locator = function(project_root, resolve_uri)
      captured.locator = { project_root = project_root, resolve_uri = resolve_uri }
      return deps.locator
    end,
    store = function(locator)
      assert.equals(deps.locator, locator)
      return deps.store
    end,
    keymaps = function() return deps.keymaps end,
    sidebar = function(opts)
      captured.sidebar = opts
      return deps.sidebar
    end,
    lsp = function(locator, config)
      captured.lsp = { locator = locator, config = config }
      return deps.lsp
    end,
    presenter = function(opts)
      captured.presenter = opts
      return deps.presenter
    end,
  }
  local session = Session.native(function() return vim.deepcopy(deps.config) end, deps.runtime, factories)
  assert.is_true(session:open())
  assert.same({
    project_root = deps.project_root,
    resolve_uri = deps.config.storage.resolve_uri,
  }, captured.locator)
  assert.equals(deps.locator, captured.lsp.locator)
  assert.same(deps.config, captured.lsp.config)
  assert.same(deps.config.navigation, captured.presenter.navigation)

  local row = { kind = "location", owner_id = deps.root_id }
  local calls = {}
  session.activate_row = function(_, value) calls.activate = value end
  session.edit_note = function(_, value) calls.note = value end
  session.toggle_row = function(_, value) calls.toggle = value end
  session.save = function() calls.save = true end
  session.load = function() calls.load = true end
  session.close = function(_, source) calls.close = source end
  session.set_current = function(_, node_id) calls.current = node_id end
  session.choose_jump_window = function() return deps.origin_win end

  captured.sidebar.handlers.activate(row)
  captured.sidebar.handlers.note(row)
  captured.sidebar.handlers.toggle(row)
  captured.sidebar.handlers.save()
  captured.sidebar.handlers.load()
  captured.sidebar.handlers.close()
  assert.equals(row, calls.activate)
  assert.equals(row, calls.note)
  assert.equals(row, calls.toggle)
  assert.is_true(calls.save)
  assert.is_true(calls.load)
  assert.equals("sidebar", calls.close)

  captured.sidebar.handlers.external_close()
  assert.equals("external_popup", calls.close)
  assert.equals(deps.origin_win, captured.presenter.choose_window())
  captured.presenter.set_current(deps.root_id)
  assert.equals(deps.root_id, calls.current)
  assert.equals(deps.flow:location(deps.root_id), captured.presenter.resolve_node(deps.root_id))
end)
```

Run: `make test-unit TEST_FILE=tests/unit/session_spec.lua`

Expected: FAIL because `Session.native` does not exist.

- [ ] **Step 8: Implement the native factory graph**

Add this third, optional argument only for dependency injection; production callers pass the first two arguments:

```lua
function Session.native(config_provider, runtime, overrides)
  local Locator = require("voyager.locator")
  local Store = require("voyager.store")
  local Schema = require("voyager.schema")
  local Flow = require("voyager.flow")
  local Keymaps = require("voyager.keymaps")
  local Sidebar = require("voyager.sidebar")
  local Actions = require("voyager.lsp.actions")
  local Normalize = require("voyager.lsp.normalize")
  local RequestGroup = require("voyager.lsp.request_group")
  local Lsp = require("voyager.lsp")
  local Presentation = require("voyager.lsp.presentation")

  local factories = vim.tbl_extend("force", {
    flow = Flow,
    locator = function(project_root, resolve_uri)
      return Locator.new(runtime, project_root, resolve_uri)
    end,
    store = function(locator)
      return Store.new({ runtime = runtime, schema = Schema, locator = locator, flow = Flow })
    end,
    keymaps = function()
      return Keymaps.new({ notify = runtime.notify })
    end,
    sidebar = function(opts)
      return Sidebar.new(opts)
    end,
    lsp = function(locator, config)
      return Lsp.new({
        actions = Actions,
        normalizer = Normalize.new({ locator = locator }),
        request_group = RequestGroup,
        get_clients = runtime.get_clients,
        make_position_params = runtime.make_position_params,
        timer = runtime.timer,
        select = runtime.select,
      })
    end,
    presenter = function(opts)
      return Presentation.new(opts)
    end,
  }, overrides or {})

  local controller
  controller = Session.new({
    config_provider = config_provider,
    runtime = runtime,
    flow = factories.flow,
    locator_factory = factories.locator,
    store_factory = factories.store,
    keymaps_factory = factories.keymaps,
    sidebar_factory = function(config)
      return factories.sidebar({
        sidebar = config.sidebar,
        keymaps = config.sidebar_keymaps,
        handlers = {
          activate = function(row) return controller:activate_row(row) end,
          note = function(row) return controller:edit_note(row) end,
          save = function() return controller:save() end,
          load = function() return controller:load() end,
          toggle = function(row) return controller:toggle_row(row) end,
          close = function() return controller:close("sidebar") end,
          external_close = function() return controller:close("external_popup") end,
        },
        notify = runtime.notify,
      })
    end,
    lsp_factory = factories.lsp,
    presenter_factory = function(config)
      return factories.presenter({
        navigation = config.navigation,
        resolve_node = function(node_id) return controller:_resolve_location(node_id) end,
        choose_window = function() return controller:choose_jump_window() end,
        set_current = function(node_id) return controller:set_current(node_id) end,
        notify = runtime.notify,
      })
    end,
    ui = { input = runtime.input, select = runtime.select, notify = runtime.notify },
  })
  return controller
end
```

Implement `controller:_resolve_location(node_id)` as an internal ID lookup against the active flow, returning nil while inactive. The factories are invoked for each new/opened flow so configuration changed during an active session applies only to the next session snapshot.

- [ ] **Step 9: Run and commit lifecycle**

Run the session spec and `make test-unit`.

Expected: all PASS.

```bash
git add lua/voyager/session.lua tests/helpers/fake_session_deps.lua tests/unit/session_spec.lua
git commit -m "feat: manage Voyager session lifecycle"
```

### Task 15: Asynchronous navigation orchestration

**Files:**
- Modify: `lua/voyager/session.lua`
- Modify: `tests/unit/session_spec.lua`
- Create: `tests/unit/session_lsp_races_spec.lua`

- [ ] **Step 1: Write the synchronous-completion regression first**

Create `tests/unit/session_lsp_races_spec.lua` with an LSP fake that calls completion inside `start` before returning its handle:

```lua
session:run_action("definition")
assert.equals(0, session:state().request_count)
assert.equals(1, #session:state().flow.root.actions)
assert.is_nil(session:state().request_handles[1])
assert.equals(render_count_before + 2, sidebar.render_count) -- pending header, then settled tree/header
```

Assert request count increments and rerenders the header before `lsp:start`, decrements and rerenders exactly once for success, empty, partial, error, timeout, unsupported, cancellation, supersession, and thrown setup failure, and stores the returned handle by request token only if completion has not already finalized. Make the fake call completion twice and assert the second call changes neither count, render count, tree, notifications, nor handle state.

- [ ] **Step 2: Specify manual-origin atomic commits and current claims**

Place the source cursor outside logical current. Assert session captures a staged manual location but the flow remains unchanged while the request is pending. On success/empty, one atomic `flow:commit_navigation` creates `voyager/manual` plus the requested action. On error, unsupported, picker cancellation, or supersession, neither appears.

Assert a still-owned manual claim makes the manual location current before presentation; a singleton/selected result overrides it; list/empty leaves manual current; and a newer action or explicit current change prevents the old completion from moving current while still allowing a non-interactive older standard result to record silently. Starting the newer action must synchronously call `supersede_interactive()` on every older live handle before dispatching the new request. An older standard/single-item handle treats that call as a no-op; an older open/required hierarchy picker completes `superseded` immediately, decrements the counter, rerenders, and ignores its eventual provider callback.

- [ ] **Step 3: Implement `run_action` and outcome commit**

Add:

```lua
session:run_action(action_name)
```

Capture `generation`, monotonically increasing `request_token`, source `bufnr`/`winid`, project root, exact cursor, cursor locator/range, logical origin node ID, optional manual location, and Neovim's invocation-time tag data before starting anything asynchronous:

```lua
local from = self._runtime.getpos(winid)
from[1] = bufnr
local tagname = self._runtime.word_at_cursor(bufnr, winid)
local context = {
  generation = state.generation,
  request_token = request_token,
  origin_node_id = origin_node_id,
  bufnr = bufnr,
  winid = winid,
  project_root = state.project_root,
  timeout_ms = state.config.navigation.timeout_ms,
  cursor = { line = cursor_row - 1, character = cursor_byte_col },
  cursor_locator = cursor_locator,
  cursor_range = cursor_range,
  manual_location = manual_location,
  from = from,
  tagname = tagname ~= "" and tagname or "<anonymous>",
}
```

Increment `request_token`, make it the presentation/current-claim owner, and invalidate the previous manual claim. Iterate a snapshot of `request_handles` and call `supersede_interactive()` before adding the new request count. Then increment `request_count`, rerender, and call `lsp:start` under `pcall`. Pass only immutable values in `context`; no callback may retain a flow node table.

Use a closure-local `settled` guard. The completion path sets it before external calls, removes `request_handles[request_token]`, and decrements `request_count` with a floor assertion. It then applies or rejects the outcome and performs exactly one final rerender, so even a non-committing error updates the request header without adding an extra render. If `lsp:start` throws, synthesize one `error` outcome through that same finalizer. After `start` returns, store the handle only when `settled == false`, the generation is still active, and the handle is not already done.

On valid successful/partial/empty completion, call:

```lua
local commit = flow:commit_navigation({
  origin_node_id = outcome.origin_node_id,
  manual_location = context.manual_location,
  method = outcome.method,
  label = outcome.label,
  locations = outcome.locations,
})
```

Map every item through the commit result without mutating the LSP outcome:

```lua
local tagged_items = {}
for _, item in ipairs(outcome.items) do
  local node_id = assert(commit.node_id_by_identity[item.identity], "committed result identity is missing")
  local tagged = vim.deepcopy(item)
  tagged.node_id = node_id
  table.insert(tagged_items, tagged)
end
```

If the still-owned manual claim exists, call `flow:set_current(commit.effective_origin_id)` before presentation. Perform the final rerender with the committed tree and already-decremented request count. Call `presenter:present(context, tagged_items, outcome.action)` only when generation/flow IDs still match and `request_token` is the newest presentation owner; older non-interactive results rerender silently. Empty results never call the presenter. Summarize partial failures once with the action label. Error/timeout/unsupported/cancelled/superseded outcomes never call `commit_navigation`; they still perform the one settled rerender and notify according to the design's concise label/reason rule.

- [ ] **Step 4: Specify overlap, save, load, and close races**

Add exact newest-first and oldest-first overlap cases. Assert request-count/render transitions `0 -> 1 -> 2 -> 1 -> 0`, both non-superseded branches record beneath captured origin IDs, and only the newest token calls the presenter. Add close/load generation rejection, pending request cancellation on teardown, save replacement with active IDs retained, post-save completion creating a new dirty epoch, stale custom `select`, and every timer/picker callback after close becoming a no-op. In each case assert the final header shows zero requests and there is no handle entry for a settled token.

- [ ] **Step 5: Wire presentation selection back into session**

`set_current(node_id)` validates a current-flow location, journals only a real change, invalidates manual current claims, rerenders, and never jumps by itself. The presenter calls it only after a verified jump/list/custom selection. Register its list observer through the session augroup and invalidate it on every load/close.

- [ ] **Step 6: Run and commit navigation orchestration**

Run: `make test-unit TEST_FILE=tests/unit/session_lsp_races_spec.lua`

Run: `make test-unit TEST_FILE=tests/unit/session_spec.lua`

Run: `make test-unit`

Expected: all PASS.

```bash
git add lua/voyager/session.lua tests/unit/session_spec.lua tests/unit/session_lsp_races_spec.lua
git commit -m "feat: record asynchronous navigation"
```

### Task 16: Typed row actions, notes, explicit save, and load

**Files:**
- Modify: `lua/voyager/session.lua`
- Modify: `tests/helpers/fake_session_deps.lua`
- Modify: `tests/unit/session_spec.lua`
- Modify: `tests/unit/sidebar_spec.lua`

- [ ] **Step 1: Specify every row/key combination**

Build a table test for location, action, and note rows against `activate`, `note`, and `toggle`. Location/note activation jumps and sets current; action activation/toggle changes collapse; note delegates to its location; inapplicable actions notify without mutation. Save, load, and close handlers must work regardless of selected row.

- [ ] **Step 2: Specify navigation fallback and stale behavior**

Assert activation chooses the recent eligible window, then a normal current-tab window; never creates a split; warns and preserves logical current when none exists; uses loaded-buffer-first source resolution; retries non-file resolvers; refuses stale locations without removing them; and opens folds after a valid byte-column jump.

- [ ] **Step 3: Specify note normalization and callback tokens**

Add:

```lua
session:edit_note({ kind = "location", owner_id = node_id })
ui.input_callback("  important\r\nfor auth  ")
assert.equals("important for auth", flow:location(node_id).note)
```

Cover prefill, empty clear, identical no-op, cancel, note-row delegation, and late callbacks rejected by generation, flow ID, node ID, and a monotonically increasing note-input token.

- [ ] **Step 4: Implement row activation and notes**

Add `activate_row`, `toggle_row`, and `edit_note`. Normalize notes by replacing each CR/LF run with one space, trimming both ends, and storing nil for empty. Resolve referenced IDs at callback time; never close over a node table.

- [ ] **Step 5: Specify serialized dirty decisions and save failure**

Test untouched root closes immediately. A dirty close/load enters `deciding` and uses one `vim.ui.select` with Save, Discard, Cancel. The first lifecycle intent wins; later ones notify and cannot replace its callback. Save transitions `active -> saving -> active`, calls synchronous `store:save`, replaces the active flow on success, clears journal/dirty state, and resumes the winning close/load intent. Failure restores pre-save dirty state, keeps the session open, and remounts after external-popup close.

- [ ] **Step 6: Implement explicit save**

Add:

```lua
session:save(on_success_optional)
```

Reject when inactive or another lifecycle phase owns the session. Do not yield during store merge/write/tree replacement. If a request callback is pending, its ID resolution occurs against the merged active tree after save.

- [ ] **Step 7: Specify saved-flow picking and replacement**

Test no-session load project selection, active-session fixed project root, empty store, invalid entries skipped with warnings, latest-first metadata, picker cancel, selection followed by dirty decision, late picker/decision callbacks, valid saved current jump/clean state, stale saved current repairing to root/dirty state, and no-window preservation of saved logical current. A selected entry must be passed to `store:load(entry, project_root)` before any active state is replaced.

Add these focused inactive/load-failure examples before implementation:

```lua
it("atomically activates a selected flow when no session exists", function()
  local session, deps = FakeSessionDeps.closed_with_saved_flow()
  session:load()
  assert.same({ deps.project_root }, deps.store.list_calls)

  deps.ui.select_callback(deps.entry, 1)
  assert.same({ { deps.entry, deps.project_root } }, deps.store.load_calls)
  assert.is_true(session:is_active())
  assert.equals(deps.loaded_flow, session:state().flow)
  assert.equals(deps.project_root, session:state().project_root)
  assert.equals(1, #deps.sidebar.mount_calls)
  assert.is_false(deps.sidebar.mount_calls[1].focus)
  assert.same({ deps.origin_buf }, deps.keymaps.applied_buffers)
  assert.equals(deps.loaded_flow.current_node_id, deps.jump_calls[1].node_id)
end)

it("leaves an inactive controller untouched when the selected document cannot load", function()
  local session, deps = FakeSessionDeps.closed_with_saved_flow()
  deps.store.load_result = nil
  deps.store.load_error = "flow changed after listing"
  session:load()
  deps.ui.select_callback(deps.entry, 1)

  assert.is_false(session:is_active())
  assert.equals(0, #deps.sidebar.mount_calls)
  assert.same({}, deps.keymaps.applied_buffers)
  assert.matches("flow changed after listing", deps.notifications[1])
end)

it("retires an active flow only after the loaded sidebar mounts", function()
  local session, deps = FakeSessionDeps.active_clean_with_saved_flow()
  local original = session:state().flow
  local generation = session:state().generation
  local registered = deps.register_autocmd_calls
  deps.loaded_sidebar.on_mount = function()
    assert.equals(original, session:state().flow)
    assert.equals(generation, session:state().generation)
    assert.equals(0, #deps.old_request.cancel_calls)
    assert.equals(0, deps.old_presenter.invalidate_calls)
    assert.same({}, deps.old_keymaps.restored_generations)
  end

  session:load()
  deps.ui.select_callback(deps.entry, 1)

  assert.same({ { deps.entry, deps.project_root } }, deps.store.load_calls)
  assert.equals(deps.loaded_flow, session:state().flow)
  assert.equals(generation + 1, session:state().generation)
  assert.equals(deps.loaded_sidebar, session:state().sidebar)
  assert.equals(1, #deps.old_request.cancel_calls)
  assert.equals(1, deps.old_presenter.invalidate_calls)
  assert.same({ generation }, deps.old_keymaps.restored_generations)
  assert.equals(1, #deps.loaded_sidebar.mount_calls)
  assert.equals(registered + 1, deps.register_autocmd_calls)
  assert.same({ deps.origin_buf }, deps.loaded_keymaps.applied_buffers)
end)

it("does not replace an active flow when mounting the loaded flow fails", function()
  local session, deps = FakeSessionDeps.active_dirty()
  local original = session:state().flow
  local generation = session:state().generation
  local old_mounts = #deps.sidebar.mount_calls
  deps.loaded_sidebar.mount_result = nil
  deps.loaded_sidebar.mount_error = "editor must be at least 24 columns wide"
  session:load()
  deps.ui.select_callback(deps.entry, 1)
  deps.ui.decision_callback("Discard", 2)

  assert.equals(original, session:state().flow)
  assert.equals(generation, session:state().generation)
  assert.equals("active", session:state().phase)
  assert.equals(0, #deps.old_request.cancel_calls)
  assert.equals(0, deps.old_presenter.invalidate_calls)
  assert.same({}, deps.old_keymaps.restored_generations)
  assert.equals(old_mounts + 1, #deps.sidebar.mount_calls) -- rollback remount
  assert.matches("24 columns", deps.notifications[#deps.notifications])
end)
```

Run: `make test-unit TEST_FILE=tests/unit/session_spec.lua`

Expected: FAIL because load does not yet call `store:load` or stage/commit an inactive or active session replacement.

- [ ] **Step 8: Implement load orchestration**

Add:

```lua
session:load()
```

Implement the load path in this order:

```lua
function Session:load()
  local active = self:is_active()
  local load_context = {
    bufnr = self._runtime.current_buf(),
    winid = self._runtime.current_win(),
    tabpage = self._runtime.current_tabpage(),
  }
  local project_root
  if active then
    project_root = self._state.project_root
  else
    local bufnr = load_context.bufnr
    if self:_is_normal_named_buffer(bufnr) then
      local discovery = self._store_factory(nil)
      project_root = discovery:project_root(
        bufnr,
        self._runtime.get_clients({ bufnr = bufnr }),
        self._runtime.cwd()
      )
    else
      project_root = self._runtime.cwd()
    end
  end

  local config = self._config_provider()
  local locator = self._locator_factory(project_root, config.storage.resolve_uri)
  local store = self._store_factory(locator)
  local entries, warnings = store:list(project_root)
  for _, warning in ipairs(warnings) do
    self._ui.notify(warning, vim.log.levels.WARN)
  end
  if #entries == 0 then
    self._ui.notify("Voyager: no saved flows for " .. project_root, vim.log.levels.INFO)
    return
  end

  local token = self:_replace_interaction_token("flow_picker")
  self._ui.select(entries, {
    prompt = "Load Voyager flow",
    format_item = function(entry)
      return string.format("%s — %s — %s", entry.name, entry.display_path, entry.updated_at)
    end,
  }, function(entry)
    if not self:_valid_interaction(token) or entry == nil then
      return
    end

    local candidate, err = store:load(entry, project_root)
    if not candidate then
      self._ui.notify("Voyager load failed: " .. err, vim.log.levels.ERROR)
      return
    end

    local function install()
      return self:_install_loaded_flow(candidate, project_root, config, locator, store, load_context)
    end
    if self:is_active() and self._state.flow:is_dirty() then
      self:_decide_dirty("load", install)
    else
      install()
    end
  end)
end
```

Make `_install_loaded_flow` the only mutation point and use the same side-effect-free state builder as `open`:

```lua
function Session:_install_loaded_flow(candidate, project_root, config, locator, store, load_context)
  local old = self:is_active() and self._state or nil
  local previous_generation = self._state.generation
  local current = candidate:location(candidate.current_node_id)
  if current == nil or locator:is_stale(current) then
    candidate:set_current(candidate.root.id) -- the repair intentionally remains dirty
  end

  local staged = self:_stage_state({
    phase = "active",
    generation = previous_generation + 1,
    config = config,
    flow = candidate,
    project_root = project_root,
    locator = locator,
    store = store,
    origin_buf = load_context.bufnr,
    origin_win = load_context.winid,
    tabpage = load_context.tabpage,
    source_windows = old and vim.deepcopy(old.source_windows) or nil,
  })

  -- Keep one popup at all times: hide the old one under its internal-close guard,
  -- mount the staged one, and remount the old popup if the geometry/NUI gate fails.
  if old then
    old.sidebar:unmount({ owned = true })
  end
  local mounted, reason = staged.sidebar:mount({
    tabpage = load_context.tabpage,
    focus = false,
  })
  if not mounted then
    reason = reason or "could not mount sidebar"
    staged.sidebar:unmount({ owned = true })
    if old then
      local restored = old.sidebar:mount({ tabpage = load_context.tabpage, focus = false })
      if restored then
        old.sidebar:render(old.flow, {
          dirty = old.flow:is_dirty(),
          request_count = old.request_count,
        })
      end
    end
    self._ui.notify("Voyager load failed: " .. reason, vim.log.levels.ERROR)
    return nil, reason
  end

  -- Nothing above this point changes logical session state or retires old services.
  if old then
    old.phase = "replacing"
    old.generation = staged.generation -- reject synchronous cancellation callbacks
    self:_invalidate_interactions(old)
    for _, handle in pairs(old.request_handles) do
      handle:cancel("load")
    end
    old.presenter:invalidate()
    old.keymaps:restore_all(previous_generation)
    self:_delete_autocmds(old)
  end

  self._state = staged
  self:_register_autocmds(staged)
  self:_apply_source_mappings(staged)
  staged.sidebar:render(staged.flow, { dirty = staged.flow:is_dirty(), request_count = 0 })
  self:_jump_loaded_current(staged)
  return true
end
```

`_stage_state` calls all per-session factories and initializes fresh request/interaction/presentation ownership without editor side effects. For an inactive load it derives source-window eligibility from `origin_buf`/`origin_win`; for an active load it filters the copied recency list against the loaded flow and fixed project root. `_register_autocmds`, `_apply_source_mappings`, `_delete_autocmds`, and `_jump_loaded_current` take the explicit state shown above. The jump helper refuses a stale target, uses the ordinary no-split chooser, and leaves `candidate.current_node_id` unchanged when no window is available. Thus a valid saved current stays clean, while the explicit stale-to-root repair stays dirty and jumps only when that root is navigable.

- [ ] **Step 9: Run and commit interactions**

Run session/sidebar specs and `make test-unit`.

Expected: all PASS.

```bash
git add lua/voyager/session.lua tests/helpers/fake_session_deps.lua tests/unit/session_spec.lua tests/unit/sidebar_spec.lua
git commit -m "feat: annotate and persist flow sessions"
```

### Task 17: Public API, five commands, and prototype removal

**Files:**
- Replace: `lua/voyager.lua`
- Replace: `plugin/voyager.lua`
- Create: `tests/unit/public_spec.lua`
- Delete: `lua/voyager/locations_stack.lua`
- Delete: `lua/voyager/lsp_client.lua`
- Delete: `lua/voyager/spinner.lua`
- Delete: `lua/voyager/ui.lua`
- Delete: `lua/voyager/utils/lsp_utils.lua`
- Delete: `lua/voyager/utils/lua_utils.lua`
- Delete: `lua/voyager/utils/ui_utils.lua`

- [ ] **Step 1: Specify the façade and command matrix**

Create `tests/unit/public_spec.lua`. Assert `setup(opts)` validates immediately and changes only future session snapshots. Assert all five commands exist and delegate:

```lua
vim.cmd("runtime plugin/voyager.lua")
for _, command in ipairs({ "VoyagerOpen", "VoyagerFocus", "VoyagerSave", "VoyagerLoad", "VoyagerClose" }) do
  assert.equals(2, vim.fn.exists(":" .. command))
end
```

Cover every active/inactive behavior from the design table, `VoyagerOpen` on unnamed/special buffers, repeated open, and no global mapping created by setup/plugin load.

- [ ] **Step 2: Run public tests red**

Run: `make test-unit TEST_FILE=tests/unit/public_spec.lua`

Expected: FAIL because only Open/Close exist and the old façade lacks the new methods.

- [ ] **Step 3: Replace `lua/voyager.lua`**

Implement:

```lua
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

function M.open() session():open() end
function M.focus() session():focus() end
function M.save() session():save() end
function M.load() session():load() end
function M.close() session():close("command") end

function M._reset_for_tests()
  if active_session then
    active_session:shutdown()
  end
  active_session = nil
  configured = Config.resolve({})
end

return M
```

`Session.native` and its sidebar-handler/presenter-callback composition were implemented and made green in Task 14. The public façade only supplies the current immutable configuration provider and `Runtime.native()`; it must not reconstruct or override that graph.

- [ ] **Step 4: Replace command registration**

Replace `plugin/voyager.lua` with five `nvim_create_user_command` calls delegating to `open`, `focus`, `save`, `load`, and `close`, all with `{ nargs = 0 }`.

- [ ] **Step 5: Delete prototype modules and prove no reachability**

Delete the eight listed prototype files. Run:

```bash
rg -n "locations_stack|lsp_client|voyager.spinner|voyager.ui|utils\.lsp_utils|utils\.lua_utils|utils\.ui_utils|buf_request_all" lua plugin tests
```

Expected: no matches.

- [ ] **Step 6: Run and commit the cutover**

Run public tests, `make test-unit`, and `make format-check`.

Expected: all PASS.

```bash
git add lua plugin tests/unit/public_spec.lua
git commit -m "feat: expose Voyager flow commands"
```

### Task 18: Deterministic LSP fixture and restart journey

**Files:**
- Create: `tests/fixtures/lsp/server.lua`
- Create: `tests/fixtures/project/lua/main.lua`
- Create: `tests/fixtures/project/lua/mysql_store.lua`
- Create: `tests/fixtures/project/lua/memory_store.lua`
- Create: `tests/fixtures/project/lua/auth.lua`
- Create: `tests/e2e/minimal_init.lua`
- Create: `tests/e2e/save_phase_spec.lua`
- Create: `tests/e2e/load_phase_spec.lua`
- Modify: `Makefile`
- Modify: `lua/voyager.lua`

- [ ] **Step 1: Create the four-file fixture project**

Create `tests/fixtures/project/lua/main.lua`:

```lua
local mysql_store = require("mysql_store")
local memory_store = require("memory_store")
local auth = require("auth")

local function main()
  local value = "account"
  mysql_store.save(value)
  memory_store.save(value)
  return auth.authorize(value)
end

return { main = main }
```

Create `tests/fixtures/project/lua/mysql_store.lua`; the emoji before `save` on the same line is the mixed-encoding sentinel:

```lua
-- stylua: ignore
local marker = "😀"; local function save(value)
  return marker .. ":mysql:" .. value
end

return { save = save }
```

Create `tests/fixtures/project/lua/memory_store.lua`:

```lua
local function save(value)
  return "memory:" .. value
end

return { save = save }
```

Create `tests/fixtures/project/lua/auth.lua`:

```lua
local mysql_store = require("mysql_store")
local memory_store = require("memory_store")

local function authorize(value)
  local mysql = mysql_store.save(value)
  local memory = memory_store.save(value)
  return mysql ~= "" and memory ~= ""
end

return { authorize = authorize }
```

- [ ] **Step 2: Implement a tiny stdio JSON-RPC server**

Create `tests/fixtures/lsp/server.lua` with this complete blocking server:

```lua
local encoding = assert(arg[1], "position encoding is required")
local root = assert(arg[2], "fixture root is required")
assert(encoding == "utf-8" or encoding == "utf-16", "unsupported fixture encoding")
root = vim.fs.normalize(root)

local function read_exact(length)
  local chunks = {}
  while length > 0 do
    local chunk = io.read(length)
    if chunk == nil or chunk == "" then
      return nil
    end
    table.insert(chunks, chunk)
    length = length - #chunk
  end
  return table.concat(chunks)
end

local function read_message()
  local length
  while true do
    local line = io.read("*l")
    if line == nil then
      return nil
    end
    line = line:gsub("\r$", "")
    if line == "" then
      break
    end
    length = tonumber(line:match("^[Cc]ontent%-[Ll]ength:%s*(%d+)")) or length
  end
  return vim.json.decode(assert(read_exact(assert(length, "missing Content-Length"))))
end

local function send(payload)
  local body = vim.json.encode(payload)
  io.write("Content-Length: " .. #body .. "\r\n\r\n" .. body)
  io.flush()
end

local function respond(id, result)
  send({ jsonrpc = "2.0", id = id, result = result == nil and vim.NIL or result })
end

local function respond_error(id, code, message)
  send({ jsonrpc = "2.0", id = id, error = { code = code, message = message } })
end

local files = {}
for _, filename in ipairs({ "main.lua", "mysql_store.lua", "memory_store.lua", "auth.lua" }) do
  local path = root .. "/lua/" .. filename
  local handle = assert(io.open(path, "rb"))
  local text = assert(handle:read("*a"))
  assert(handle:close())
  files[filename] = vim.split(text, "\n", { plain = true })
  if files[filename][#files[filename]] == "" then
    table.remove(files[filename])
  end
end

local function uri(filename)
  return vim.uri_from_fname(root .. "/lua/" .. filename)
end

local function protocol_character(line, byte_col)
  return vim.str_utfindex(line, encoding, byte_col, true)
end

local function find_range(filename, needle)
  for row, line in ipairs(assert(files[filename])) do
    local start_byte = assert(line:find(needle, 1, true), filename .. " missing " .. needle) - 1
    local end_byte = start_byte + #needle
    return {
      start = { line = row - 1, character = protocol_character(line, start_byte) },
      ["end"] = { line = row - 1, character = protocol_character(line, end_byte) },
    }
  end
  error(filename .. " missing " .. needle)
end

local function line_range(filename, selection)
  local line = files[filename][selection.start.line + 1]
  return {
    start = { line = selection.start.line, character = 0 },
    ["end"] = { line = selection.start.line, character = protocol_character(line, #line) },
  }
end

local function location(filename, needle)
  return { uri = uri(filename), range = find_range(filename, needle) }
end

local function location_link(filename, needle)
  local selection = find_range(filename, needle)
  return {
    targetUri = uri(filename),
    targetRange = line_range(filename, selection),
    targetSelectionRange = selection,
  }
end

local function hierarchy_item(filename, name)
  local selection = find_range(filename, name)
  return {
    name = name,
    kind = 12,
    detail = filename,
    uri = uri(filename),
    range = line_range(filename, selection),
    selectionRange = selection,
    data = { fixture = true, encoding = encoding, filename = filename },
  }
end

local function references(params)
  local document_uri = params.textDocument.uri
  if document_uri == uri("mysql_store.lua") then
    return { location("auth.lua", "mysql_store.save") }
  end
  if document_uri == uri("memory_store.lua") then
    return { location("auth.lua", "memory_store.save") }
  end
  return {
    location("auth.lua", "mysql_store.save"),
    location("auth.lua", "memory_store.save"),
  }
end

local function prepared(params)
  local document_uri = params.textDocument.uri
  if document_uri == uri("mysql_store.lua") then
    return { hierarchy_item("mysql_store.lua", "save") }
  end
  if document_uri == uri("memory_store.lua") then
    return { hierarchy_item("memory_store.lua", "save") }
  end
  if document_uri == uri("auth.lua") then
    return { hierarchy_item("auth.lua", "authorize") }
  end
  return { hierarchy_item("main.lua", "main") }
end

local function incoming_calls(params)
  local item = params.item
  if item.uri == uri("mysql_store.lua") then
    return { {
      from = hierarchy_item("auth.lua", "authorize"),
      fromRanges = { find_range("auth.lua", "mysql_store.save") },
    } }
  end
  if item.uri == uri("memory_store.lua") then
    return { {
      from = hierarchy_item("auth.lua", "authorize"),
      fromRanges = { find_range("auth.lua", "memory_store.save") },
    } }
  end
  if item.uri == uri("auth.lua") then
    return { {
      from = hierarchy_item("main.lua", "main"),
      fromRanges = { find_range("main.lua", "auth.authorize") },
    } }
  end
  return {}
end

local function outgoing_calls(params)
  local item = params.item
  if item.uri == uri("main.lua") then
    return {
      { to = hierarchy_item("mysql_store.lua", "save"), fromRanges = { find_range("main.lua", "mysql_store.save") } },
      { to = hierarchy_item("memory_store.lua", "save"), fromRanges = { find_range("main.lua", "memory_store.save") } },
      { to = hierarchy_item("auth.lua", "authorize"), fromRanges = { find_range("main.lua", "auth.authorize") } },
    }
  end
  if item.uri == uri("auth.lua") then
    return {
      { to = hierarchy_item("mysql_store.lua", "save"), fromRanges = { find_range("auth.lua", "mysql_store.save") } },
      { to = hierarchy_item("memory_store.lua", "save"), fromRanges = { find_range("auth.lua", "memory_store.save") } },
    }
  end
  return {}
end

local function action_result(method, params)
  if method == "textDocument/definition" then
    return true, location_link("auth.lua", "authorize")
  elseif method == "textDocument/declaration" then
    return true, location("auth.lua", "authorize")
  elseif method == "textDocument/references" then
    return true, references(params)
  elseif method == "textDocument/implementation" then
    return true, {
      location_link("mysql_store.lua", "save"),
      location("memory_store.lua", "save"),
    }
  elseif method == "textDocument/typeDefinition" then
    return true, location("auth.lua", "authorize")
  elseif method == "textDocument/prepareCallHierarchy" then
    return true, prepared(params)
  elseif method == "callHierarchy/incomingCalls" then
    return true, incoming_calls(params)
  elseif method == "callHierarchy/outgoingCalls" then
    return true, outgoing_calls(params)
  end
  return false
end

while true do
  local message = read_message()
  if message == nil then
    break
  end
  local method = message.method
  if method == "exit" then
    break
  elseif message.id == nil then
    -- `initialized`, didOpen/didChange/didClose, and $/cancelRequest are notifications.
  elseif method == "initialize" then
    respond(message.id, {
      capabilities = {
        positionEncoding = encoding,
        textDocumentSync = 1,
        definitionProvider = true,
        declarationProvider = true,
        referencesProvider = true,
        implementationProvider = true,
        typeDefinitionProvider = true,
        callHierarchyProvider = true,
      },
      serverInfo = { name = "voyager-fixture-" .. encoding, version = "1" },
    })
  elseif method == "shutdown" then
    respond(message.id, nil)
  else
    local known, result = action_result(method, message.params or {})
    if known then
      respond(message.id, result)
    else
      respond_error(message.id, -32601, "method not found: " .. tostring(method))
    end
  end
end
```

- [ ] **Step 3: Add an e2e init that starts both encodings**

Create `tests/e2e/minimal_init.lua`:

```lua
dofile(vim.fn.getcwd() .. "/tests/minimal_init.lua")

vim.lsp.set_log_level("debug")
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
  E2E.wait("two fixture clients attaching to buffer " .. bufnr, function()
    local seen = {}
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
      seen[client.name] = true
    end
    return seen["voyager-fixture-utf8"] and seen["voyager-fixture-utf16"]
  end)
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
  local client_id = assert(vim.lsp.start({
    name = "voyager-fixture-" .. encoding:gsub("-", ""),
    cmd = { vim.v.progpath, "--clean", "--headless", "-l", server_path, encoding, fixture_root },
    root_dir = fixture_root,
  }, { bufnr = E2E.source_buf }), "failed to start " .. encoding .. " fixture client")
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
```

The per-buffer autocmd is fixture-owned, not Voyager-owned. It makes the same two deterministic clients available after Voyager lazily opens another fixture file; no user LSP configuration is consulted.

- [ ] **Step 4: Write the save phase through real modules**

Create `tests/e2e/save_phase_spec.lua`:

```lua
local E2E = assert(_G.VoyagerE2E)
local Schema = require("voyager.schema")
local Voyager = require("voyager")

local function row(kind, owner_id)
  return { kind = kind, owner_id = owner_id }
end

describe("Voyager restart journey: save phase", function()
  it("records, annotates, and saves the complete branch", function()
    local input_calls = 0
    vim.ui.input = function(opts, callback)
      input_calls = input_calls + 1
      assert.is_nil(opts.default)
      callback("important for auth")
    end

    Voyager.open()
    local session = assert(Voyager._session_for_tests())
    assert.is_true(session:is_active())
    local opened = session:state()
    assert.is_true(opened.sidebar:is_mounted())
    assert.equals(E2E.source_win, vim.api.nvim_get_current_win())
    assert.equals(E2E.source_buf, vim.api.nvim_win_get_buf(E2E.source_win))

    local popup_win
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
      if opened.sidebar:owns_window(winid) then
        popup_win = winid
      end
    end
    assert.is_not_nil(popup_win)
    assert.equals("nofile", vim.bo[vim.api.nvim_win_get_buf(popup_win)].buftype)

    session:run_action("implementation")
    E2E.wait_for_requests(session)
    local flow = session:state().flow
    local implementations = assert(E2E.action(flow.root, "textDocument/implementation"))
    assert.equals(2, #implementations.results)
    assert.equals(4, #vim.fn.getqflist())
    local mysql = assert(E2E.result(implementations, "lua/mysql_store.lua"))
    local memory = assert(E2E.result(implementations, "lua/memory_store.lua"))

    session:activate_row(row("location", mysql.id))
    E2E.wait_for_clients(vim.api.nvim_get_current_buf())
    session:run_action("references")
    E2E.wait_for_requests(session)
    flow = session:state().flow
    implementations = assert(E2E.action(flow.root, "textDocument/implementation"))
    mysql = assert(E2E.result(implementations, "lua/mysql_store.lua"))
    local references = assert(E2E.action(mysql, "textDocument/references"))
    assert.equals(1, #references.results)
    assert.equals(2, #vim.fn.getqflist())

    session:activate_row(row("location", flow.root.id))
    flow = session:state().flow
    implementations = assert(E2E.action(flow.root, "textDocument/implementation"))
    memory = assert(E2E.result(implementations, "lua/memory_store.lua"))
    session:activate_row(row("location", memory.id))
    session:edit_note(row("location", memory.id))
    assert.equals(1, input_calls)
    session:toggle_row(row("action", implementations.id))

    flow = session:state().flow
    implementations = assert(E2E.action(flow.root, "textDocument/implementation"))
    memory = assert(E2E.result(implementations, "lua/memory_store.lua"))
    assert.equals(memory.id, flow.current_node_id)
    assert.equals("important for auth", memory.note)
    assert.is_true(implementations.collapsed)
    session:save()
    assert.is_false(session:state().flow:is_dirty())

    local paths = vim.fn.glob(E2E.root .. "/.voyager/flows/*.json", false, true)
    assert.equals(1, #paths)
    local encoded = table.concat(vim.fn.readfile(paths[1]), "\n") .. "\n"
    local saved = Schema.decode(encoded)
    assert.equals(memory.id, saved.current_node_id)

    local retained_buf = vim.api.nvim_get_current_buf()
    local retained_cursor = vim.api.nvim_win_get_cursor(0)
    local retained_list = vim.fn.getqflist({ id = 0, items = 0 })
    local augroup = session:state().augroup
    Voyager.close()

    local closed = assert(Voyager._session_for_tests()):state()
    assert.equals("closed", closed.phase)
    assert.equals(0, closed.request_count)
    assert.equals(0, vim.tbl_count(closed.request_handles))
    assert.is_false(vim.api.nvim_win_is_valid(popup_win))
    assert.equals(retained_buf, vim.api.nvim_get_current_buf())
    assert.same(retained_cursor, vim.api.nvim_win_get_cursor(0))
    assert.equals(retained_list.id, vim.fn.getqflist({ id = 0 }).id)
    assert.equals(#retained_list.items, #vim.fn.getqflist())
    local autocmd_ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = augroup })
    assert.is_true(not autocmd_ok or #autocmds == 0)
    assert.is_false(closed.keymaps:is_installed(retained_buf, "gri"))
  end)
end)
```

- [ ] **Step 5: Write the independent load phase**

Create `tests/e2e/load_phase_spec.lua`; this file runs in a second Neovim process and shares only the copied fixture directory:

```lua
local E2E = assert(_G.VoyagerE2E)
local Voyager = require("voyager")

describe("Voyager restart journey: load phase", function()
  it("loads the independently persisted branch and tears down cleanly", function()
    local select_calls = 0
    vim.ui.select = function(items, opts, callback)
      select_calls = select_calls + 1
      assert.is_true(#items > 0)
      assert.is_function(opts.format_item)
      callback(items[1], 1)
    end

    Voyager.load()
    E2E.wait("saved flow activation", function()
      local session = Voyager._session_for_tests()
      return session ~= nil and session:is_active()
    end)

    local session = assert(Voyager._session_for_tests())
    assert.equals(1, select_calls)
    local state = session:state()
    local flow = state.flow
    local implementations = assert(E2E.action(flow.root, "textDocument/implementation"))
    assert.equals(2, #implementations.results)
    assert.is_true(implementations.collapsed)
    local mysql = assert(E2E.result(implementations, "lua/mysql_store.lua"))
    local memory = assert(E2E.result(implementations, "lua/memory_store.lua"))
    local references = assert(E2E.action(mysql, "textDocument/references"))
    assert.equals(1, #references.results)
    assert.equals("important for auth", memory.note)
    assert.equals(memory.id, flow.current_node_id)
    assert.is_false(flow:is_dirty())
    assert.is_true(state.sidebar:is_mounted())

    local popup_win
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
      if state.sidebar:owns_window(winid) then
        popup_win = winid
      end
    end
    assert.is_not_nil(popup_win)
    local augroup = state.augroup
    Voyager.close()

    local closed = assert(Voyager._session_for_tests()):state()
    assert.equals("closed", closed.phase)
    assert.equals(0, closed.request_count)
    assert.equals(0, vim.tbl_count(closed.request_handles))
    assert.is_false(vim.api.nvim_win_is_valid(popup_win))
    local autocmd_ok, autocmds = pcall(vim.api.nvim_get_autocmds, { group = augroup })
    assert.is_true(not autocmd_ok or #autocmds == 0)
  end)
end)
```

Add this test-only accessor to `lua/voyager.lua`:

```lua
function M._session_for_tests()
  return active_session
end
```

- [ ] **Step 6: Add the isolated two-process E2E target**

Task 1 intentionally defined `test` as unit-only. Merge these definitions into `Makefile` so this task is the point where the full aggregate begins running E2E. The equality guard makes the only recursive cleanup target explicit; the save and load processes use separate XDG roots and share only the copied project containing the saved flow:

```make
E2E_PROJECT := $(ROOT)/.tmp/e2e-project
E2E_SAVE_ENV := env VOYAGER_TEST_ROOT=$(ROOT) VOYAGER_E2E_ROOT=$(E2E_PROJECT) NVIM_APPNAME=voyager-e2e-save XDG_CONFIG_HOME=$(ROOT)/.tmp/e2e-save/config XDG_CACHE_HOME=$(ROOT)/.tmp/e2e-save/cache XDG_STATE_HOME=$(ROOT)/.tmp/e2e-save/state XDG_DATA_HOME=$(ROOT)/.tmp/e2e-save/data
E2E_LOAD_ENV := env VOYAGER_TEST_ROOT=$(ROOT) VOYAGER_E2E_ROOT=$(E2E_PROJECT) NVIM_APPNAME=voyager-e2e-load XDG_CONFIG_HOME=$(ROOT)/.tmp/e2e-load/config XDG_CACHE_HOME=$(ROOT)/.tmp/e2e-load/cache XDG_STATE_HOME=$(ROOT)/.tmp/e2e-load/state XDG_DATA_HOME=$(ROOT)/.tmp/e2e-load/data

.PHONY: test-e2e

test: test-unit test-e2e

test-e2e: check-deps
	@test "$(E2E_PROJECT)" = "$(ROOT)/.tmp/e2e-project"
	@rm -rf "$(E2E_PROJECT)"
	@mkdir -p "$(E2E_PROJECT)"
	@cp -R tests/fixtures/project/. "$(E2E_PROJECT)/"
	@$(E2E_SAVE_ENV) $(NVIM) --headless --noplugin -i NONE -u tests/e2e/minimal_init.lua -c "PlenaryBustedFile tests/e2e/save_phase_spec.lua"
	@$(E2E_LOAD_ENV) $(NVIM) --headless --noplugin -i NONE -u tests/e2e/minimal_init.lua -c "PlenaryBustedFile tests/e2e/load_phase_spec.lua"
```

Do not append `qa!`: Plenary owns process exit and propagates `cquit` on failure. Every asynchronous wait in these files is bounded at five seconds and includes the LSP log tail.

- [ ] **Step 7: Run and commit the restart journey**

Run: `make test-e2e`

Run: `make test`

Expected: both fresh-process phases and all unit tests PASS; neither uses a user's language servers.

```bash
git add Makefile lua/voyager.lua tests/e2e tests/fixtures
git commit -m "test: cover the saved flow journey"
```

### Task 19: Voyager README and generated help

**Files:**
- Replace: `README.md`
- Replace: `doc/voyager.txt`
- Create: `doc/tags`
- Modify: `Makefile`

- [ ] **Step 1: Replace all template documentation**

Write a Voyager-specific README with these complete sections in this order: purpose and tree example; requirements (`Neovim 0.12.4`, `nui.nvim`); lazy.nvim and packer installation; minimal setup; all five commands; default LSP/sidebar mapping tables; the complete setup table from the approved spec; exploration/manual-connector behavior; notes; `.voyager/flows` save/merge/load behavior; non-file URI resolver example; lifecycle/cleanup guarantees; development commands; and release-status caveat.

Use this minimal setup verbatim:

```lua
require("voyager").setup()
vim.keymap.set("n", "<leader>vo", "<cmd>VoyagerOpen<cr>")
vim.keymap.set("n", "<leader>vl", "<cmd>VoyagerLoad<cr>")
```

Do not describe implicit global mappings, autosave, older Neovim support, or arbitrary global LSP observation.

- [ ] **Step 2: Add an exact local panvimdoc generator**

Extend the Makefile dependency constants and `deps`/`check-deps` recipes:

```make
CONTAINER ?= docker
PANVIMDOC := $(DEPS)/panvimdoc
PANVIMDOC_REV := 662fb20304d20c539fb48a0bda628f5165507de7
DOC_DATE := 2026 August 01

deps:
	@scripts/ensure-dependency install panvimdoc https://github.com/kdheepak/panvimdoc.git $(PANVIMDOC_REV) $(PANVIMDOC)

check-deps:
	@scripts/ensure-dependency check panvimdoc https://github.com/kdheepak/panvimdoc.git $(PANVIMDOC_REV) $(PANVIMDOC)

docs: check-deps
	@$(CONTAINER) build -t voyager-panvimdoc:4.0.1 $(PANVIMDOC)
	@$(CONTAINER) run --rm -v $(ROOT):/work -w /work voyager-panvimdoc:4.0.1 --project-name voyager --input-file README.md --vim-version "Neovim 0.12.4" --toc true --description "Persistent branching LSP navigation flows" --title-date-pattern "$(DOC_DATE)" --dedup-subheadings true --demojify true --treesitter true --ignore-rawblocks true --doc-mapping false --doc-mapping-project-name true --shift-heading-level-by 0 --increment-heading-level-by 0
```

Merge these additional recipes into the existing `deps` and `check-deps` targets; do not replace the NUI/Plenary recipes. `DOC_DATE` is the approved design date expressed as a literal `strftime` pattern with no `%` directives, so generation never reads the wall clock. Keep that value fixed until a deliberate documentation-date change is committed together with regenerated help.

- [ ] **Step 3: Generate and validate help**

Run `make deps`, then `make docs`. This generates `doc/voyager.txt` from README with pinned panvimdoc v4.0.1. Then run:

```bash
nvim --headless -u NONE -i NONE -c "helptags doc" -c "qa!"
```

Commit the resulting `doc/tags` so `:help voyager` and every command/config tag resolve.

- [ ] **Step 4: Add documentation checks**

Add Make targets:

```make
help-check:
	@$(MAKE) docs
	@$(NVIM) --headless -u NONE -i NONE -c "helptags doc" -c "qa!"
	@git diff --exit-code -- doc/voyager.txt doc/tags
```

CI calls this same `help-check` target, so local and CI generation share the pinned source, literal date, container command, and drift check.

- [ ] **Step 5: Verify and commit docs**

Run: `make help-check`

Run: `rg -n "plugin template|my-template|Neovim >= 0\.8|plugin_name" README.md doc`

Expected: help check PASS and no stale template matches outside historical design context.

```bash
git add README.md doc Makefile
git commit -m "docs: document Voyager navigation flows"
```

### Task 20: LuaRock packaging and installed-artifact smoke test

**Files:**
- Create: `voyager.nvim-scm-1.rockspec`
- Modify: `Makefile`
- Create: `tests/smoke/installed.lua`

- [ ] **Step 1: Create the rockspec with the runtime dependency**

Create `voyager.nvim-scm-1.rockspec`:

```lua
package = "voyager.nvim"
version = "scm-1"
source = {
  url = "git+https://github.com/lazymaniac/voyager.nvim.git",
}
description = {
  summary = "Persistent branching LSP navigation flows for Neovim",
  detailed = "Explore LSP destinations as a branching tree, annotate nodes, and save project-local flows.",
  homepage = "https://github.com/lazymaniac/voyager.nvim",
  license = "MIT",
}
dependencies = {
  "lua >= 5.1",
  "nui.nvim == 0.4.0-1",
}
build = {
  type = "builtin",
  modules = {
    ["voyager"] = "lua/voyager.lua",
    ["voyager.config"] = "lua/voyager/config.lua",
    ["voyager.runtime"] = "lua/voyager/runtime.lua",
    ["voyager.locator"] = "lua/voyager/locator.lua",
    ["voyager.flow"] = "lua/voyager/flow.lua",
    ["voyager.schema"] = "lua/voyager/schema.lua",
    ["voyager.store"] = "lua/voyager/store.lua",
    ["voyager.keymaps"] = "lua/voyager/keymaps.lua",
    ["voyager.sidebar"] = "lua/voyager/sidebar.lua",
    ["voyager.session"] = "lua/voyager/session.lua",
    ["voyager.lsp"] = "lua/voyager/lsp.lua",
    ["voyager.lsp.actions"] = "lua/voyager/lsp/actions.lua",
    ["voyager.lsp.normalize"] = "lua/voyager/lsp/normalize.lua",
    ["voyager.lsp.request_group"] = "lua/voyager/lsp/request_group.lua",
    ["voyager.lsp.call_hierarchy"] = "lua/voyager/lsp/call_hierarchy.lua",
    ["voyager.lsp.presentation"] = "lua/voyager/lsp/presentation.lua",
  },
  copy_directories = { "plugin", "doc" },
}
```

- [ ] **Step 2: Add installed-artifact commands**

Merge these variables and targets into `Makefile`:

```make
LUAROCKS ?= luarocks
LUAROCKS_VERSION := 3.13.0
ROCKSPEC := voyager.nvim-scm-1.rockspec
ROCK_BUILD_OUTPUT := $(ROOT)/voyager.nvim-scm-1.all.rock
ROCK_ARTIFACT_DIR := $(ROOT)/.tmp/artifacts
ROCK_FILE := $(ROCK_ARTIFACT_DIR)/voyager.nvim-scm-1.all.rock
ROCK_TREE := $(ROOT)/.tmp/rocks

.PHONY: check-luarocks rock rock-smoke

check-luarocks:
	@command -v $(LUAROCKS) >/dev/null 2>&1 || { echo "LuaRocks $(LUAROCKS_VERSION) is required" >&2; exit 1; }
	@actual="$$($(LUAROCKS) --version | awk 'NR == 1 { print $$NF }')"; test "$$actual" = "$(LUAROCKS_VERSION)" || { echo "expected LuaRocks $(LUAROCKS_VERSION), got $$actual" >&2; exit 1; }

rock: check-luarocks
	@test "$(ROCK_BUILD_OUTPUT)" = "$(ROOT)/voyager.nvim-scm-1.all.rock"
	@rm -f "$(ROCK_BUILD_OUTPUT)"
	@mkdir -p "$(ROCK_ARTIFACT_DIR)"
	@$(LUAROCKS) make --pack-binary-rock --deps-mode=none "$(ROCKSPEC)"
	@test -f "$(ROCK_BUILD_OUTPUT)"
	@mv "$(ROCK_BUILD_OUTPUT)" "$(ROCK_FILE)"

rock-smoke: rock
	@test "$(ROCK_TREE)" = "$(ROOT)/.tmp/rocks"
	@rm -rf "$(ROCK_TREE)"
	@mkdir -p "$(ROCK_TREE)"
	@$(LUAROCKS) --tree "$(ROCK_TREE)" install nui.nvim 0.4.0-1
	@$(LUAROCKS) --tree "$(ROCK_TREE)" install "$(ROCK_FILE)" --deps-mode=none
	@rock_dir="$$($(LUAROCKS) --tree "$(ROCK_TREE)" show --rock-dir voyager.nvim scm-1)"; \
	  test -n "$$rock_dir"; \
	  lua_path="$$($(LUAROCKS) --tree "$(ROCK_TREE)" path --lr-path)"; \
	  lua_cpath="$$($(LUAROCKS) --tree "$(ROCK_TREE)" path --lr-cpath)"; \
	  VOYAGER_ROCK_DIR="$$rock_dir" LUA_PATH="$$lua_path;;" LUA_CPATH="$$lua_cpath;;" \
	  $(NVIM) --headless --noplugin -u NONE -i NONE \
	    --cmd 'execute "set runtimepath^=" .. fnameescape($$VOYAGER_ROCK_DIR)' \
	    -c "runtime plugin/voyager.lua" -l tests/smoke/installed.lua
```

The explicit equality checks guard the two cleanup targets. `rock` moves the only root-level build product into ignored `.tmp/artifacts`, and `rock-smoke` loads Lua modules solely through the clean tree's `LUA_PATH`/`LUA_CPATH` while runtime files come from the installed rock directory; do not add the source checkout or `.deps` to runtimepath.

Create `tests/smoke/installed.lua`:

```lua
local voyager = require("voyager")
assert(type(voyager.setup) == "function")
for _, command in ipairs({ "VoyagerOpen", "VoyagerFocus", "VoyagerSave", "VoyagerLoad", "VoyagerClose" }) do
  assert(vim.fn.exists(":" .. command) == 2, command .. " is not registered")
end
vim.cmd("qa!")
```

- [ ] **Step 3: Build and install without publishing**

Run: `make rock`

Run: `make rock-smoke`

Expected: one local binary rock is built, installed with NUI into a clean tree, and smoke-loaded. No upload occurs.

- [ ] **Step 4: Commit packaging**

```bash
git add voyager.nvim-scm-1.rockspec Makefile tests/smoke/installed.lua
git commit -m "build: package Voyager as a LuaRock"
```

### Task 21: Pinned quality and gated release workflows

**Files:**
- Modify: `Makefile`
- Create: `.github/workflows/quality.yml`
- Replace: `.github/workflows/lint-test.yml`
- Delete: `.github/workflows/docs.yml`
- Replace: `.github/workflows/release.yml`

- [ ] **Step 1: Create one reusable quality workflow**

Use only these immutable action revisions:

```text
actions/checkout                         11bd71901bbe5b1630ceea73d27597364c9af683
rhysd/action-setup-vim                   febef33995d6649302e9d88dda81e071b68f16a7
JohnnyMorganz/stylua-action              479972f01e665acfcba96ada452c36608bdbbb5e
raven-actions/actionlint                 3d39aea434753780c3b3d4a1a31c854b4dbf49d7
nvim-neorocks/luarocks-tag-release       adbca66e871a519055f4917c6af5fbf19f656f5d
```

The action wrapper and tool have different repositories. Pin the wrapper to the SHA above, and pin the local actionlint 1.7.12 tool to upstream `rhysd/actionlint` commit `914e7df21a07ef503a81201c76d2b11c789d3fca`. Add this local workflow-lint preflight to `Makefile`:

```make
GO ?= go
ACTIONLINT_VERSION := 1.7.12
ACTIONLINT_REV := 914e7df21a07ef503a81201c76d2b11c789d3fca
ACTIONLINT_DIR := $(ROOT)/.tmp/tools/actionlint-$(ACTIONLINT_REV)
ACTIONLINT_BIN := $(ACTIONLINT_DIR)/actionlint

.PHONY: check-actionlint workflow-lint

$(ACTIONLINT_BIN):
	@command -v $(GO) >/dev/null 2>&1 || { echo "Go is required to install actionlint $(ACTIONLINT_VERSION)" >&2; exit 1; }
	@mkdir -p "$(ACTIONLINT_DIR)"
	@GOBIN="$(ACTIONLINT_DIR)" $(GO) install github.com/rhysd/actionlint/cmd/actionlint@$(ACTIONLINT_REV)

check-actionlint: $(ACTIONLINT_BIN)
	@actual="$$($(ACTIONLINT_BIN) -version | sed -n '1p')"; test "$$actual" = "$(ACTIONLINT_VERSION)" || { echo "expected actionlint $(ACTIONLINT_VERSION), got $$actual" >&2; exit 1; }

workflow-lint: check-actionlint
	@$(ACTIONLINT_BIN) .github/workflows/*.yml
```

Create `.github/workflows/quality.yml` exactly as follows. The LuaRocks archive is both version-pinned and SHA-512 verified before installation:

```yaml
name: quality

on:
  workflow_call:

permissions:
  contents: read

jobs:
  quality:
    runs-on: ubuntu-24.04
    env:
      LUAROCKS_VERSION: 3.13.0
      LUAROCKS_SHA512: 44381bb7fd3d474f92b0d2d0bf492246907f88ac6d5bdbb30b889222d755681777042195cfbfa136c068e05db78896760d5aea28c2f60a46d2f30c4c28ba704b
    steps:
      - name: Check out source
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683

      - name: Install Neovim 0.12.4
        uses: rhysd/action-setup-vim@febef33995d6649302e9d88dda81e071b68f16a7
        with:
          neovim: true
          version: v0.12.4

      - name: Check Lua formatting with StyleLua 2.5.2
        uses: JohnnyMorganz/stylua-action@479972f01e665acfcba96ada452c36608bdbbb5e
        with:
          version: v2.5.2
          args: --check lua plugin tests

      - name: Install Lua 5.1 build prerequisites
        run: |
          sudo apt-get update
          sudo apt-get install --yes build-essential curl lua5.1 liblua5.1-0-dev

      - name: Install LuaRocks 3.13.0
        run: |
          archive=/tmp/luarocks-${LUAROCKS_VERSION}.tar.gz
          source_dir=/tmp/luarocks-${LUAROCKS_VERSION}
          curl --fail --location --silent --show-error \
            --output "$archive" \
            "https://luarocks.github.io/luarocks/releases/luarocks-${LUAROCKS_VERSION}.tar.gz"
          echo "${LUAROCKS_SHA512}  ${archive}" | sha512sum --check --strict
          tar --extract --gzip --file "$archive" --directory /tmp
          cd "$source_dir"
          ./configure --lua-version=5.1 --with-lua-include=/usr/include/lua5.1
          make
          sudo make install
          test "$(luarocks --version | awk 'NR == 1 { print $NF }')" = "$LUAROCKS_VERSION"

      - name: Install pinned test and documentation dependencies
        run: make deps

      - name: Run unit and restart E2E tests
        run: make test

      - name: Verify generated help and tags
        run: make help-check

      - name: Build and smoke-load installed rock
        run: make rock-smoke

      - name: Verify local actionlint 1.7.12 target
        run: make workflow-lint

      - name: Lint workflows through the pinned action wrapper
        uses: raven-actions/actionlint@3d39aea434753780c3b3d4a1a31c854b4dbf49d7
        with:
          version: 1.7.12
```

`make help-check` is the sole documentation generator in CI; it uses the pinned panvimdoc checkout and literal date from Task 19, then verifies both `doc/voyager.txt` and `doc/tags`.

Pin every future third-party action to a full 40-character SHA as well.

- [ ] **Step 2: Replace push/PR CI with the reusable caller**

Replace `.github/workflows/lint-test.yml` with:

```yaml
name: lint-test

on:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  quality:
    uses: ./.github/workflows/quality.yml
```

Delete the auto-committing `.github/workflows/docs.yml`; documentation drift must fail, never mutate `main` from CI.

- [ ] **Step 3: Gate tag publishing behind quality and repository readiness**

Replace `.github/workflows/release.yml` with:

```yaml
name: release

on:
  push:
    tags:
      - "v*"

permissions:
  contents: read

jobs:
  quality:
    uses: ./.github/workflows/quality.yml

  publish:
    needs: quality
    if: ${{ vars.ENABLE_LUAROCKS_PUBLISH == 'true' }}
    runs-on: ubuntu-24.04
    permissions:
      contents: write
    steps:
      - name: Check out release tag
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
        with:
          fetch-depth: 0

      - name: Publish Voyager to LuaRocks
        uses: nvim-neorocks/luarocks-tag-release@adbca66e871a519055f4917c6af5fbf19f656f5d
        env:
          LUAROCKS_API_KEY: ${{ secrets.LUAROCKS_API_KEY }}
        with:
          name: voyager.nvim
          dependencies: |
            nui.nvim == 0.4.0-1
          copy_directories: |
            plugin
            doc
          summary: Persistent branching LSP navigation flows for Neovim
          detailed_description: Explore LSP destinations as a branching tree, annotate nodes, and save project-local flows.
          license: MIT
```

The workflow-level token is read-only. Only the quality-gated, repository-variable-gated publish job receives `contents: write`; the API key is scoped to that single action step. This keeps tags non-publishing until the source repository is publicly accessible to the selected publisher or a private-compatible source is adopted.

- [ ] **Step 4: Validate workflows and commit**

Run: `make workflow-lint`

Run: `make format-check && make test && make help-check && make rock && make rock-smoke && make workflow-lint`

Expected: all PASS locally; workflow files contain no floating `@vN`, `@main`, `stable`, `nightly`, or `latest` action references.

```bash
git add Makefile .github/workflows
git commit -m "ci: verify Voyager release artifacts"
```

### Task 22: Final acceptance and release-readiness report

**Files:**
- Modify only files exposed by the verification failures below

- [ ] **Step 1: Run formatting and full automated verification fresh**

Run:

```bash
make deps
make check-deps check-stylua check-luarocks check-actionlint
make format-check
make test
make help-check
make rock
make rock-smoke
make workflow-lint
```

Expected: every command exits 0 with Neovim 0.12.4, clean dependency worktrees, StyleLua 2.5.2, LuaRocks 3.13.0, and actionlint 1.7.12. `make test` runs both unit and two-process E2E suites after Task 18.

- [ ] **Step 2: Run static cleanup checks**

Run:

```bash
rg -n "TODO|TBD|FIXME|plugin template|plugin_name|buf_request_all|voyager\.spinner|voyager\.locations_stack" lua plugin tests README.md doc .github
rg -n 'uses: [^ ]+@(v[0-9]+|main|master|stable|nightly|latest)([[:space:]]|$)' .github/workflows
test ! -e voyager.nvim-scm-1.all.rock
git diff --check
git status --short
```

Expected: both `rg` commands exit 1 with no matches, the root-level rock does not exist because it was moved to ignored `.tmp/artifacts`, `git diff --check` exits 0, and `git status --short` lists only intentional branch changes.

- [ ] **Step 3: Perform the real acceptance journey**

Use a real project and one attached server supporting implementations and references. Record each row as PASS or FAIL while executing it in order:

| Check | Exact observation |
| --- | --- |
| Environment | `:version` reports NVIM v0.12.4; `:lua =vim.lsp.get_clients({bufnr=0})` identifies the server used |
| Open | Place the cursor on a named symbol, run `:VoyagerOpen`, and observe one popup while the source window remains visible |
| First branch | Invoke the implementation wrapper, select the first result, invoke references, and observe references nested beneath that result |
| Sibling branch | Return to the root row, invoke implementations again, select a different result, and observe both siblings retained |
| Persisted view state | Add the exact note `important for auth`, collapse one action, select a non-root location, and run `:VoyagerSave` |
| Disk artifact | Record the single matching `<project-root>/.voyager/flows/<flow-id>.json` path and verify it decodes with `:lua =require("voyager.schema").decode(table.concat(vim.fn.readfile(<quoted-path>), "\n"))` |
| Teardown | Run `:VoyagerClose`; the popup, Voyager-local mappings, autocmds, and requests disappear, while the selected code cursor and result list remain |
| Restart/load | Exit Neovim, start a new Neovim process in the same project, attach the same server, run `:VoyagerLoad`, choose the saved flow, and observe both branches, nested references, note, collapse state, and non-root current marker |
| Final teardown | Run `:VoyagerClose` again and repeat the ownership observation above |

The handoff message must include Neovim version, server name, project root, exact flow JSON path, and the PASS/FAIL value for all nine rows. Do not add a repository report file.

- [ ] **Step 4: Commit only if verification required a code correction**

If Step 1-3 exposed a defect, add a focused regression test first, make it red, implement the smallest correction, rerun the entire verification set, then commit the exact affected files with a conventional message describing that correction. If all checks pass unchanged, create no empty commit.

## Completion definition

Implementation is complete only when all 22 task checkpoints are complete, every task that changed files has its focused commit, the full automated command set passes from a clean checkout after `make deps`, the real acceptance journey passes, and public publishing remains gated unless repository-source compatibility is verified. At that point use `superpowers:requesting-code-review`, resolve any findings with `superpowers:receiving-code-review`, rerun `superpowers:verification-before-completion`, and finish the branch with `superpowers:finishing-a-development-branch`.
