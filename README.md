# Voyager.nvim

Voyager is an automatic, project-local call-tree explorer for Neovim. Put the
cursor on a symbol and run `:VoyagerOpen`; Voyager discovers the complete
reachable call tree and keeps it in a compact side popup.

```text
▾ ▲ callers of Checkout.submit (1)
   [m] Api.checkout — api/checkout.lua:17
▾ ▲ callers of Store.save (2)
   [m] Checkout.submit — services/checkout.lua:41
   [m] Retry.flush — jobs/retry.lua:28
● [m] Store.save — stores/store.lua:12
▾ ▼ calls from Store.save (2)
   [m] Db.write — db/client.lua:73
   [m] Audit.log — audit/log.lua:9
▾ ▼ calls from Db.write (1)
   [m] Pool.execute — db/pool.lua:54
```

Callers continue upward from the starting symbol; callees continue downward.
The single `●` marks the active canonical node. When the active node changes,
Voyager centers it in the popup without hiding the rest of the tree. The
sidebar cursor is only a selection cursor, so browsing rows does not move the
dot or your source window.

Tree creation is automatic, with no manual steps or depth controls. Voyager
follows incoming and outgoing LSP call hierarchy until it exhausts the
reachable project graph. Files outside the canonical project root, common
dependency/vendor directories, and non-file URIs are excluded before they can
enter the tree, so library calls cannot make it overflow. Cycles and converging
paths reuse existing nodes through cross-links instead of expanding forever.

## Requirements

- Neovim 0.12.4
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim)
- An LSP server with call hierarchy support
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

Voyager does not create global mappings. Add the entry points you want:

```lua
require("voyager").setup()
vim.keymap.set("n", "<leader>vo", "<cmd>VoyagerOpen<cr>")
vim.keymap.set("n", "<leader>vl", "<cmd>VoyagerLoad<cr>")
```

## Commands

| Command | Behavior |
| --- | --- |
| `:VoyagerOpen` | Automatically create a full call tree for the symbol under the cursor, or focus the active tree |
| `:VoyagerFocus` | Focus or remount the active sidebar |
| `:VoyagerSave` | Explicitly save or merge the active tree |
| `:VoyagerLoad` | Pick a saved tree for the current project |
| `:VoyagerClose` | Close Voyager, prompting when the tree is dirty |
| `:VoyagerToggle` | Open Voyager, or close it when a session is active |
| `:VoyagerExport` | Send every resolvable tree location to the quickfix list |

<!-- panvimdoc-include-comment

:VoyagerOpen
: Automatically create a full call tree for the symbol under the cursor, or focus the active tree.

:VoyagerFocus
: Focus or remount the active sidebar.

:VoyagerSave
: Explicitly save or merge the active tree.

:VoyagerLoad
: Pick a saved tree for the current project.

:VoyagerClose
: Close Voyager, prompting when the tree is dirty.

:VoyagerToggle
: Open Voyager, or close it when a session is active.

:VoyagerExport
: Send every resolvable tree location to the quickfix list.

-->

## Automatic call tree

`:VoyagerOpen` captures the symbol under the source cursor immediately. It then
starts two independent traversals from that root:

- Incoming traversal places direct callers above the root and continues through
  callers of those callers.
- Outgoing traversal places direct callees below the root and continues through
  calls made by those callees.

This is deliberately two-sided rather than a walk of every edge in every
direction. It answers “who reaches this symbol?” above and “what can this symbol
reach?” below without pulling sibling branches into the tree.

There is no configured depth or subject limit. `navigation.concurrency` limits
only how many LSP requests may run at once; it does not truncate the result.
Rows appear as requests finish, and the popup header shows when creation is
still running. A timeout, unsupported symbol, or malformed server result stops
that branch safely while completed branches remain usable.

Every candidate is checked against the canonical project root before its source
is read, stored, or scheduled. Common in-root dependency and vendor trees, such
as `node_modules`, `.venv`, `vendor`, and `third_party`, are excluded as well.
An LSP workspace that spans an entire filesystem is treated as too broad;
Voyager falls back to the nearest Git root, containing working directory, or
source-file directory.
The displayed call site and its semantic caller/callee anchor must both be
project-local. This matters for outgoing calls, whose call site may be in your
file even when the callee belongs to an external library. Non-file documents
are excluded from automatically generated trees.

The same canonical call occurrence is stored once. Call cycles and converging
paths render as relation cross-links to that occurrence, so
the traversal terminates when the reachable project graph is exhausted.

The popup is pinned to `sidebar.side` and grows up to `sidebar.width` and the
available editor height. Relation headers always name their origin, such as
`callers of Service.save` or `calls from Service.save`; `▲` and `▼` keep the two
directions readable without color. Test locations gather beneath a folded
`tests (N)` group.

### Sidebar mappings

| Key | Behavior |
| --- | --- |
| `<CR>` | Jump from a location or note row; toggle a relation or tests row |
| `o` | Jump to the selected location and return focus to the sidebar |
| `p` | Peek at the selected location in a preview float |
| `x` | Unlink an occurrence, delete a relation/history branch, or clear a note |
| `n` | Add, edit, or remove a note on the selected location |
| `s` | Save or merge the active tree |
| `L` | Pick and load a saved project tree |
| `za` | Collapse or expand the selected relation section |
| `zM`, `zR` | Collapse or expand every relation section |
| `?` | Show a key reference |
| `q`, `<Esc>` | Close Voyager |

With `sidebar.preview` enabled (the default), the preview float follows the
sidebar cursor and closes when the sidebar loses focus. Set
`sidebar.preview = false` to use the explicit `p` preview, which closes on the
next cursor move.

## Configuration

`setup()` validates every option immediately. Changes made while a tree is open
apply to the next session.

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `sidebar.width` | integer | `42` | Maximum popup width; must be at least 20 |
| `sidebar.side` | `"left"` or `"right"` | `"right"` | Editor edge the popup is pinned to |
| `sidebar.border` | string | `"rounded"` | One of `none`, `single`, `double`, `rounded`, `solid`, or `shadow` |
| `sidebar.icons` | boolean or table | `true` | Nerd Font icons, plain text, or per-icon overrides including `icons.kinds` |
| `sidebar.path` | string | `"relative"` | Location paths: `relative`, `filename`, or `shortened` |
| `sidebar.preview` | boolean | `true` | Preview follows the sidebar cursor and closes on focus loss |
| `sidebar.indent` | integer | `1` | Compatibility option accepted from 0 through 8 |
| `sidebar.test_paths` | string list | common test layouts | Lua patterns that classify a location as test code |
| `navigation.timeout_ms` | integer | `10000` | Per-request-stage timeout from 100 through 120000 milliseconds |
| `navigation.concurrency` | integer | `4` | Concurrent automatic call queries from 1 through 16 |
| `sidebar_keymaps.jump_or_toggle` | keymap or false | `"<CR>"` | Activate a location/note or toggle a relation |
| `sidebar_keymaps.jump_stay` | keymap or false | `"o"` | Jump and return focus to the sidebar |
| `sidebar_keymaps.preview` | keymap or false | `"p"` | Peek at the selected location |
| `sidebar_keymaps.delete` | keymap or false | `"x"` | Unlink an occurrence, delete a relation/history branch, or clear a note |
| `sidebar_keymaps.note` | keymap or false | `"n"` | Edit a location note |
| `sidebar_keymaps.save` | keymap or false | `"s"` | Save the tree |
| `sidebar_keymaps.load` | keymap or false | `"L"` | Load a tree |
| `sidebar_keymaps.toggle` | keymap or false | `"za"` | Toggle a relation section |
| `sidebar_keymaps.collapse_all` | keymap or false | `"zM"` | Collapse every relation section |
| `sidebar_keymaps.expand_all` | keymap or false | `"zR"` | Expand every relation section |
| `sidebar_keymaps.help` | keymap or false | `"?"` | Show the key reference |
| `sidebar_keymaps.close` | keymap or false | `{ "q", "<Esc>" }` | Close Voyager |
| `storage.resolve_uri` | function or nil | `nil` | Resolve non-file locations in legacy saved flows; automatic trees still exclude them |
| `storage.autosave` | boolean | `false` | Save dirty trees automatically on close, load, and quit |

<!-- panvimdoc-include-comment

sidebar.width
: Maximum popup width; must be an integer of at least 20.

sidebar.side
: Editor edge the popup is pinned to; `left` or `right`.

sidebar.border
: NUI border style: `none`, `single`, `double`, `rounded`, `solid`, or `shadow`.

sidebar.icons
: `true` for Nerd Font icons, `false` for plain text, or a table of per-icon overrides.

sidebar.path
: Location path display: `relative`, `filename`, or `shortened`.

sidebar.preview
: Preview follows the sidebar cursor and closes on focus loss.

sidebar.indent
: Compatibility option; an integer from 0 through 8.

sidebar.test_paths
: Lua patterns that classify a location as test code.

navigation.timeout_ms
: Per-request-stage timeout from 100 through 120000 milliseconds.

navigation.concurrency
: Maximum concurrent automatic call queries; an integer from 1 through 16.

sidebar_keymaps.jump_or_toggle
: Activate a location/note or toggle a relation; a string, string list, or `false`.

sidebar_keymaps.jump_stay
: Jump and return focus to the sidebar; a string, string list, or `false`.

sidebar_keymaps.preview
: Peek at the selected location; a string, string list, or `false`.

sidebar_keymaps.delete
: Unlink an occurrence, delete a relation/history branch, or clear a note; a string, string list, or `false`.

sidebar_keymaps.note
: Edit a location note; a string, string list, or `false`.

sidebar_keymaps.save
: Save the tree; a string, string list, or `false`.

sidebar_keymaps.load
: Load a tree; a string, string list, or `false`.

sidebar_keymaps.toggle
: Toggle a relation section; a string, string list, or `false`.

sidebar_keymaps.collapse_all
: Collapse every relation section; a string, string list, or `false`.

sidebar_keymaps.expand_all
: Expand every relation section; a string, string list, or `false`.

sidebar_keymaps.help
: Show the key reference; a string, string list, or `false`.

sidebar_keymaps.close
: Close Voyager; a string, string list, or `false`.

storage.resolve_uri
: Optional resolver for non-file locations in legacy saved flows. Automatically generated trees always exclude non-file locations.

storage.autosave
: Save dirty trees automatically on close, load, and quit.

-->

A sidebar `keymap` is a string or non-empty string list. Set a mapping to
`false` to disable it. Enabled mappings must have distinct, non-empty
normal-mode left-hand sides after Neovim keycode normalization.

## Active node and navigation

Only the active canonical node gets `●` and the full-line
`VoyagerCurrentLine` highlight. A cross-link alias to that node remains visible
without a second dot. Activating a location with `<CR>` or `o` moves the logical
current node, reveals its folded parent path, and centers its canonical row in
the popup. The whole tree remains available above and below the viewport.

Moving the source cursor onto a displayed call occurrence or its stored symbol
anchor also makes that node active and centers its canonical row automatically.

Moving the sidebar selection highlights related aliases and relation headers,
but it does not change the logical current node. This lets you inspect the tree
without losing your place. `o` performs a real jump and then returns focus to
the sidebar; `<CR>` leaves focus in the source window.

Every location has a symbol-kind badge and a project-relative source position.
`sidebar.path` can show the full relative path, only the filename, or a shortened
path. Missing or changed saved locations remain visible as stale rows instead
of being silently removed. `:VoyagerExport` sends every currently resolvable
location to the quickfix list.

Press `x` to remove the selected relation occurrence while preserving a shared
canonical location used elsewhere. If a location becomes unlinked, Voyager
keeps it in `unlinked history` with its notes and explored relations until that
history branch is deleted explicitly.

## Notes

Press `n` on a location or its note row. The current note is prefilled through
`vim.ui.input`; submitting a trimmed non-empty line saves it, while submitting
an empty value removes it. Cancelling leaves the note unchanged. Notes are
stored with their canonical location and appear beside every relevant path.

## Saving, merging, and loading

Saving is explicit by default. Set `storage.autosave = true` to save dirty trees
automatically on close, load, and quit instead of prompting. Each project stores
human-readable, schema-versioned JSON under:

```text
<project-root>/.voyager/flows/<flow-name>-<root-hash>.json
```

There is one logical saved tree per root identity. Before every save, Voyager
re-reads the latest valid revision and merges call relations, destinations,
cross-links, notes, collapsed state, and the current node. The merged JSON is
flushed to a unique sibling temporary file and atomically renamed. Sequential
saves therefore merge the latest completed write; truly simultaneous processes
remain last-rename-wins.

Valid older flows migrate when read, and duplicate locations are canonicalized
without losing notes or relations. `:VoyagerLoad` or sidebar `L` opens a
latest-first picker for the current project. Loading restores the saved tree; it
does not replace it with the symbol currently under the cursor. Invalid files
are reported and skipped.

The `.voyager` directory is project-local and may be committed to version
control. Closing or replacing a modified tree asks whether to save, discard, or
cancel unless autosave is enabled.

## Lifecycle and cleanup

Voyager owns one process-wide session and one NUI popup. With no active session,
`:VoyagerOpen` captures the current symbol, mounts the popup, and starts tree
creation. Repeated opens focus the existing tree. The popup remounts across tabs
and valid resizes without creating or resizing source splits.

Closing cancels outstanding call-hierarchy requests and closes only
Voyager-owned windows. Source buffers, cursors, jumplist/tagstack entries, and
quickfix or location lists created while exploring are not rewound.

`VimLeavePre` performs teardown without a prompt, so explicitly save anything
you want to keep before exiting Neovim, or enable `storage.autosave`.

Run `:checkhealth voyager` to verify the Neovim version, `nui.nvim`, and storage
writability. For statuslines, `require("voyager").status()` returns `nil` when
Voyager is inactive. An active session returns:

```lua
{
  name = "Store.save",
  dirty = true,
  locations = 17,
  requests = 4,
}
```

`requests` is the aggregate number of in-flight LSP requests. Tree-creation
progress is deliberately not a separate public status field.

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
