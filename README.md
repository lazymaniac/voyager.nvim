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

## Default mappings

Voyager installs its LSP mappings only as session-owned, buffer-local wrappers
in eligible source buffers. It restores the previous local mappings when the
session closes.

### LSP mappings

| Action | LSP method | Key |
| --- | --- | --- |
| Definition | `textDocument/definition` | `gd` |
| Declaration | `textDocument/declaration` | `gD` |
| References | `textDocument/references` | `grr` |
| Implementations | `textDocument/implementation` | `gri` |
| Type definition | `textDocument/typeDefinition` | `grt` |
| Incoming calls | `callHierarchy/incomingCalls` | `gC` |
| Outgoing calls | `callHierarchy/outgoingCalls` | `gG` |

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
| `sidebar.width` | integer | `42` | Popup width; must be at least 20 |
| `sidebar.side` | `"left"` or `"right"` | `"right"` | Editor edge used by the popup |
| `sidebar.border` | string | `"rounded"` | One of `none`, `single`, `double`, `rounded`, `solid`, or `shadow` |
| `navigation.loclist` | boolean | `false` | Use a location list instead of quickfix where lists are presented |
| `navigation.reuse_win` | boolean | `false` | Reuse a window already showing the target when possible |
| `navigation.timeout_ms` | integer | `10000` | Per-network-stage timeout from 100 through 120000 milliseconds |
| `navigation.on_list` | function or nil | `nil` | Custom `on_list(list, select)` presenter; replaces default jump/list presentation |
| `lsp_keymaps.definition` | string or false | `"gd"` | Definition wrapper |
| `lsp_keymaps.declaration` | string or false | `"gD"` | Declaration wrapper |
| `lsp_keymaps.references` | string or false | `"grr"` | References wrapper |
| `lsp_keymaps.implementation` | string or false | `"gri"` | Implementations wrapper |
| `lsp_keymaps.type_definition` | string or false | `"grt"` | Type-definition wrapper |
| `lsp_keymaps.incoming_calls` | string or false | `"gC"` | Incoming-call wrapper |
| `lsp_keymaps.outgoing_calls` | string or false | `"gG"` | Outgoing-call wrapper |
| `sidebar_keymaps.jump_or_toggle` | keymap or false | `"<CR>"` | Activate a location/note or toggle an action |
| `sidebar_keymaps.note` | keymap or false | `"n"` | Edit a location note |
| `sidebar_keymaps.save` | keymap or false | `"s"` | Save the flow |
| `sidebar_keymaps.load` | keymap or false | `"L"` | Load a flow |
| `sidebar_keymaps.toggle` | keymap or false | `"za"` | Toggle an action subtree |
| `sidebar_keymaps.close` | keymap or false | `{ "q", "<Esc>" }` | Close Voyager |
| `storage.resolve_uri` | function or nil | `nil` | Resolve a non-file URI to a valid loaded buffer |

<!-- panvimdoc-include-comment

sidebar.width
: Popup width; must be an integer of at least 20.

sidebar.side
: Editor edge used by the popup; `left` or `right`.

sidebar.border
: NUI border style: `none`, `single`, `double`, `rounded`, `solid`, or `shadow`.

navigation.loclist
: Use a location list instead of quickfix where lists are presented.

navigation.reuse_win
: Reuse a window already showing the target when possible.

navigation.timeout_ms
: Per-network-stage timeout from 100 through 120000 milliseconds.

navigation.on_list
: Optional custom `on_list(list, select)` presenter.

lsp_keymaps.definition
: Buffer-local definition wrapper; a string or `false`.

lsp_keymaps.declaration
: Buffer-local declaration wrapper; a string or `false`.

lsp_keymaps.references
: Buffer-local references wrapper; a string or `false`.

lsp_keymaps.implementation
: Buffer-local implementations wrapper; a string or `false`.

lsp_keymaps.type_definition
: Buffer-local type-definition wrapper; a string or `false`.

lsp_keymaps.incoming_calls
: Buffer-local incoming-call wrapper; a string or `false`.

lsp_keymaps.outgoing_calls
: Buffer-local outgoing-call wrapper; a string or `false`.

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

For a custom presenter, `list` follows Neovim's `vim.lsp.LocationOpts.OnList`
shape. Call Voyager's supplied `select(item)` callback when your UI chooses a
tagged item so the destination becomes the flow's current node.

## Exploring and branching

Run one of the session LSP mappings from the current location. Voyager adds an
action row such as `implementations`, `references`, or `incoming calls`, then
records every unique normalized destination below it. Definitions,
declarations, implementations, and type definitions jump for one raw result and
open a list for multiple results. References and call hierarchy always present a
list when non-empty. Successful empty responses remain visible as an action with
zero results.

With the default list presenter, Voyager tracks destinations opened with
`<CR>`, a double-click, or a user-entered quickfix/location-list jump command
such as `:cc`, `:cnext`, or `:ll` (including command abbreviations). Neovim does
not emit an attributable event for programmatic `vim.cmd()` jumps or arbitrary
`<Cmd>`/Lua callback mappings; integrations that navigate that way should use
`navigation.on_list` and call Voyager's supplied `select(item)` callback.

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
session autocmd group, closes only Voyager-owned windows, and restores each
buffer-local mapping when Voyager still owns it. A mapping changed by another
plugin during the session is left untouched. Intentional buffers, cursors,
jumplist/tagstack entries, and quickfix or location lists created while exploring
are not rewound.

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
