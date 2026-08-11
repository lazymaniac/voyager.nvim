# Voyager.nvim

Voyager is a project-local code exploration notebook for Neovim. It records LSP
navigation as a branching tree in a small side popup, so you can return to an
earlier symbol, explore a different path, annotate useful locations, and save the
whole flow for later.

```text
● main — lua/main.lua:5
  ▾ implementations (2)
    save — lua/mysql_store.lua:2
      ▾ references (1)
        authorize — lua/auth.lua:5
    ● save — lua/memory_store.lua:1
      ✎ important for auth
```

Opening Voyager starts a new flow at the symbol under the cursor. Loading an old
flow is always an explicit action.

## Requirements

- Neovim 0.12.4
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim)
- A [Nerd Font](https://www.nerdfonts.com) for the default sidebar icons
  (optional — set `sidebar.icons = false` for plain text)

## Installation

### lazy.nvim

```lua
{
  "lazymaniac/voyager.nvim",
  dependencies = { "MunifTanjim/nui.nvim" },
  config = function()
    require("voyager").setup()
  end,
}
```

### packer.nvim

```lua
use({
  "lazymaniac/voyager.nvim",
  requires = { "MunifTanjim/nui.nvim" },
  config = function()
    require("voyager").setup()
  end,
})
```

## Minimal setup

Voyager does not create global mappings for opening or loading a flow. Add the
ones you want:

```lua
require("voyager").setup()
vim.keymap.set("n", "<leader>vo", "<cmd>VoyagerOpen<cr>")
vim.keymap.set("n", "<leader>vl", "<cmd>VoyagerLoad<cr>")
```

## Commands

| Command | Behavior |
| --- | --- |
| `:VoyagerOpen` | Start a new flow at the cursor, or focus the active flow |
| `:VoyagerFocus` | Focus or remount the active sidebar |
| `:VoyagerSave` | Explicitly save or merge the active flow |
| `:VoyagerLoad` | Pick a saved flow for the current project |
| `:VoyagerClose` | Close Voyager, prompting when the flow is dirty |

<!-- panvimdoc-include-comment

:VoyagerOpen
: Start a new flow at the cursor, or focus the active flow.

:VoyagerFocus
: Focus or remount the active sidebar.

:VoyagerSave
: Explicitly save or merge the active flow.

:VoyagerLoad
: Pick a saved flow for the current project.

:VoyagerClose
: Close Voyager, prompting when the flow is dirty.

-->

## Recording without touching your config

Voyager installs no LSP mappings, changes no options, and never wraps or
shadows a key. While a session is open it listens to the editor's own LSP
traffic (the `LspRequest` autocmd): whenever your usual mapping, picker, or
command sends one of the navigation requests below from the buffer you are
editing, Voyager runs its own read-only request for the same action and
records the results in the flow tree. Your `gd`, `gr*`, snacks, Telescope, or
any other navigation behaves exactly as it does without Voyager.

| Action | LSP method |
| --- | --- |
| Definition | `textDocument/definition` |
| Declaration | `textDocument/declaration` |
| References | `textDocument/references` |
| Implementations | `textDocument/implementation` |
| Type definition | `textDocument/typeDefinition` |
| Incoming calls | `callHierarchy/incomingCalls` |
| Outgoing calls | `callHierarchy/outgoingCalls` |

The sidebar is a compact floating card pinned to the configured editor edge.
It grows and shrinks with the flow tree instead of reserving a full column,
up to `sidebar.width` columns and the available editor height.

### Sidebar mappings

| Key | Behavior |
| --- | --- |
| `<CR>` | Jump from a location or note row; toggle an action row |
| `n` | Add, edit, or remove a note on the selected location |
| `s` | Save or merge the active flow |
| `L` | Pick and load a saved project flow |
| `za` | Collapse or expand the selected action subtree |
| `q`, `<Esc>` | Close Voyager |

## Configuration

`setup()` validates every option immediately. Changes made while a flow is open
apply to the next session.

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `sidebar.width` | integer | `42` | Maximum popup width; must be at least 20 |
| `sidebar.side` | `"left"` or `"right"` | `"right"` | Editor edge the popup is pinned to |
| `sidebar.border` | string | `"rounded"` | One of `none`, `single`, `double`, `rounded`, `solid`, or `shadow` |
| `sidebar.icons` | boolean or table | `true` | `true` for Nerd Font icons, `false` for plain text, or per-icon overrides |
| `navigation.timeout_ms` | integer | `10000` | Per-network-stage timeout from 100 through 120000 milliseconds |
| `sidebar_keymaps.jump_or_toggle` | keymap or false | `"<CR>"` | Activate a location/note or toggle an action |
| `sidebar_keymaps.note` | keymap or false | `"n"` | Edit a location note |
| `sidebar_keymaps.save` | keymap or false | `"s"` | Save the flow |
| `sidebar_keymaps.load` | keymap or false | `"L"` | Load a flow |
| `sidebar_keymaps.toggle` | keymap or false | `"za"` | Toggle an action subtree |
| `sidebar_keymaps.close` | keymap or false | `{ "q", "<Esc>" }` | Close Voyager |
| `storage.resolve_uri` | function or nil | `nil` | Resolve a non-file URI to a valid loaded buffer |

<!-- panvimdoc-include-comment

sidebar.width
: Maximum popup width; must be an integer of at least 20.

sidebar.side
: Editor edge the popup is pinned to; `left` or `right`.

sidebar.border
: NUI border style: `none`, `single`, `double`, `rounded`, `solid`, or `shadow`.

sidebar.icons
: `true` for Nerd Font icons, `false` for plain text, or a table of per-icon overrides.

navigation.timeout_ms
: Per-network-stage timeout from 100 through 120000 milliseconds.

sidebar_keymaps.jump_or_toggle
: Activate a location/note or toggle an action; a string, string list, or `false`.

sidebar_keymaps.note
: Edit a location note; a string, string list, or `false`.

sidebar_keymaps.save
: Save the flow; a string, string list, or `false`.

sidebar_keymaps.load
: Load a flow; a string, string list, or `false`.

sidebar_keymaps.toggle
: Toggle an action subtree; a string, string list, or `false`.

sidebar_keymaps.close
: Close Voyager; a string, string list, or `false`.

storage.resolve_uri
: Optional resolver from a non-file URI to a valid loaded buffer.

-->

A sidebar `keymap` is a string or non-empty string list. Mapping values set to
`false` are disabled. Enabled mappings in each group must have distinct,
non-empty normal-mode left-hand sides after Neovim keycode normalization.

## Exploring and branching

Navigate however you always do—your own mappings, Neovim's `gr*` defaults, or
a picker plugin. When a navigation request leaves the buffer you are editing,
Voyager concurrently records every unique normalized destination below an
action row such as `implementations`, `references`, or `incoming calls`.
Successful empty responses remain visible as an action with zero results.

Once an action records its destinations, Voyager watches for the cursor to land
exactly on one of them in a normal source window—through a quickfix jump, a
picker, or any other navigation—and marks that destination as the flow's
current node. Later landings on the same action's destinations keep updating
the current node until a newer action runs or you pick a node in the sidebar.

Call-hierarchy recording follows the protocol's prepare step without
prompting: when a server returns several prepared items, Voyager records calls
for the first one while your own mapping keeps its usual behavior.

Select any earlier location in the sidebar and continue from there. Its existing
children stay intact, so exploring again creates or extends a sibling branch
instead of replacing the path you already followed.

If the editor cursor no longer matches Voyager's logical current node when an
action starts, Voyager stages a `manual jump` connector for the actual source
location. The connector and LSP action are committed together only when the LSP
operation succeeds. Plain cursor movement is never recorded, and failed,
cancelled, unsupported, or superseded actions leave no synthetic branch.

## Notes

Press `n` on a location or its note row. The current note is prefilled through
`vim.ui.input`; submitting a trimmed non-empty line saves it, while submitting an
empty value removes it. Newline runs from custom input providers become spaces.
Cancelling leaves the note unchanged. Notes are persisted with their location
and can be useful for reminders such as “important for auth”.

## Saving, merging, and loading

Saving is explicit—Voyager never autosaves. Each project stores human-readable,
schema-versioned JSON under:

```text
<project-root>/.voyager/flows/<flow-name>-<root-hash>.json
```

There is one logical saved flow per root identity. Before every save, Voyager
re-reads the latest valid revision and recursively merges actions, destinations,
notes, collapsed state, and the current node. New and saved-only branches are
both retained. The merged JSON is flushed to a unique sibling temporary file and
atomically renamed; sequential saves therefore merge the latest completed write.
Truly simultaneous processes are last-rename-wins. The `.voyager` directory is
project-local and may be committed to version control.

`:VoyagerLoad` or sidebar `L` opens a latest-first project picker. Invalid files
are reported and skipped. Loading a flow replaces the current one only after any
dirty-flow decision completes. Missing or out-of-range destinations remain in
the tree as stale rows; Voyager does not silently delete them.

Closing or replacing a modified flow asks whether to save, discard, or cancel.
An untouched root-only flow closes without prompting.

## Non-file URI resolver

LSP servers can return virtual locations such as `jdt://` documents. Voyager can
persist one only when it can read the source from an already loaded URI buffer or
from `storage.resolve_uri`. Integrate your virtual-document provider by returning
the loaded buffer that contains the URI's current source text:

```lua
local virtual_documents = {}
-- Populate this table from your LSP/virtual-document plugin. The buffer may
-- have a provider-specific name; the key is the original LSP URI.
local function remember_virtual_document(uri, bufnr)
  virtual_documents[uri] = bufnr
end
require("voyager").setup({
  storage = {
    resolve_uri = function(uri)
      local bufnr = virtual_documents[uri]
      if bufnr
        and vim.api.nvim_buf_is_valid(bufnr)
        and vim.api.nvim_buf_is_loaded(bufnr)
      then
        return bufnr
      end
    end,
  },
})
```

The resolver must return a valid loaded buffer or `nil`. After a restart, the
provider must make that source available again before the saved URI node can be
navigated; otherwise Voyager marks it stale.

## Lifecycle and cleanup

Voyager owns one process-wide session and one NUI popup. `:VoyagerOpen` starts a
new flow only when no session is active; repeated opens focus the existing flow.
The popup remounts across tabs and valid resizes without creating or resizing
source splits.

Closing cancels pending LSP requests and late interaction tokens, removes the
session autocmd group, and closes only Voyager-owned windows. Intentional
buffers, cursors, jumplist/tagstack entries, and quickfix or location lists
created while exploring are not rewound.

`VimLeavePre` performs teardown without a prompt or autosave, so explicitly save
anything you want to keep before exiting Neovim.

## Development

The toolchain is pinned by the Makefile. Useful targets are:

| Command | Purpose |
| --- | --- |
| `make deps` | Install pinned local test and documentation dependencies |
| `make test-unit` | Run the deterministic unit suite |
| `make test-e2e` | Run the two-process save/restart/load journey |
| `make test` | Run unit and E2E tests |
| `make format` | Format Lua with StyleLua 2.5.2 |
| `make format-check` | Check Lua formatting without changing files |
| `make docs` | Regenerate Vim help with pinned panvimdoc |
| `make help-check` | Regenerate help/tags and fail on drift |
| `make rock` | Build the local LuaRock without publishing |
| `make rock-smoke` | Install and load the built artifact in a clean tree |
| `make workflow-lint` | Run pinned actionlint against GitHub workflows |

Documentation generation uses Docker by default. Set `CONTAINER=podman` when
using Podman, for example `make help-check CONTAINER=podman`.

## Release status

Voyager is implementation-ready work in progress, not a publicly released
package. Tag publishing remains gated until the source repository is accessible
to the selected publisher (or a private-compatible source path is adopted) and
the repository explicitly enables the release workflow. Do not treat an untagged
checkout as a supported public release.
