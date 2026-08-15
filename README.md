# Voyager.nvim

Voyager is a project-local code exploration notebook for Neovim. It records LSP
navigation as a flat relationship ledger in a small side popup, so you can return
to an earlier symbol, explore a different path, annotate useful locations, and
save the whole flow for later.

```text
▾ ▲ callers of MysqlStore.save (2)
   [m] AuthService.authorize — lua/auth.lua:5
   [m] Worker.flush — lua/worker.lua:8
● [f] MysqlStore.save — lua/mysql_store.lua:2
▾ ▼ calls from MysqlStore.save (2)
   [f] Db.exec — lua/db.lua:14
    ✎ important for auth
   [f] Log.audit — lua/log.lua:9
```

Every row starts at a fixed horizontal level, so a long call chain never drifts
out of the popup. Relation headers name their origin explicitly: callers sit
above the symbol and code it reaches sits below. Rows use `usages`, `callers`,
and `calls` instead of raw LSP method names; every destination is named after
its enclosing symbol with a kind badge, and test results fold beneath a
`tests (N)` group.

Opening Voyager stages an empty session; the flow and its starting record are
created by the first LSP navigation you make. Loading an old flow is always an
explicit action.

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
| `:VoyagerOpen` | Open a session that records from the first navigation, or focus the active flow |
| `:VoyagerFocus` | Focus or remount the active sidebar |
| `:VoyagerSave` | Explicitly save or merge the active flow |
| `:VoyagerLoad` | Pick a saved flow for the current project |
| `:VoyagerClose` | Close Voyager, prompting when the flow is dirty |
| `:VoyagerToggle` | Open Voyager, or close it when a session is active |
| `:VoyagerExport` | Send every resolvable flow location to the quickfix list |

<!-- panvimdoc-include-comment

:VoyagerOpen
: Open a session that records from the first navigation, or focus the active flow.

:VoyagerFocus
: Focus or remount the active sidebar.

:VoyagerSave
: Explicitly save or merge the active flow.

:VoyagerLoad
: Pick a saved flow for the current project.

:VoyagerClose
: Close Voyager, prompting when the flow is dirty.

:VoyagerToggle
: Open Voyager, or close it when a session is active.

:VoyagerExport
: Send every resolvable flow location to the quickfix list.

-->

## Recording without touching your config

Voyager installs no LSP mappings, changes no options, and never wraps or
shadows a key. While a session is open it listens to the editor's own LSP
traffic (the `LspRequest` autocmd): whenever your usual mapping, picker, or
command sends one of the navigation requests below from the buffer you are
editing, Voyager runs its own read-only request for the same action and
records the results in the flow ledger. Your `gd`, `gr*`, snacks, Telescope, or
any other navigation behaves exactly as it does without Voyager. The first
observed navigation also creates the flow itself, rooted at the symbol the
request started from.

| Action | LSP method | Sidebar label |
| --- | --- | --- |
| Definition | `textDocument/definition` | `definition` |
| Declaration | `textDocument/declaration` | `declaration` |
| References | `textDocument/references` | `usages` |
| Implementations | `textDocument/implementation` | `implementations` |
| Type definition | `textDocument/typeDefinition` | `type definitions` |
| Incoming calls | `callHierarchy/incomingCalls` | `callers` |
| Outgoing calls | `callHierarchy/outgoingCalls` | `calls` |

Each unanchored destination is then refined asynchronously: Voyager asks a
`textDocument/documentSymbol`-capable server (falling back to treesitter) for
the destination's enclosing symbol and kind, so a reference site renders as
`DurableObservationIngressService.accept` with a method badge instead of the
bare word under the reference. The resolved symbol-selection range is retained
as that row's query subject.

The sidebar is a compact floating card pinned to the configured editor edge.
It grows and shrinks with the recorded flow instead of reserving a full column,
up to `sidebar.width` columns and the available editor height.

### Sidebar mappings

| Key | Behavior |
| --- | --- |
| `<CR>` | Jump from a location or note row; toggle a relation or tests row |
| `o` | Jump but keep focus in the sidebar |
| `a` | Jump to the selected node and pick an LSP action to record |
| `u` | Show callers; query LSP automatically when they are not recorded |
| `d` | Show calls from the symbol; query LSP automatically when missing |
| `U`, `D` | Refresh callers or calls from LSP |
| `p` | Peek at the selected location in a preview float |
| `x` | Unlink an occurrence, delete a relation/history branch, or clear a note |
| `n` | Add, edit, or remove a note on the selected location |
| `s` | Save or merge the active flow |
| `L` | Pick and load a saved project flow |
| `za` | Collapse or expand the selected relation section |
| `zM`, `zR` | Collapse or expand every relation section |
| `?` | Show a key reference |
| `q`, `<Esc>` | Close Voyager |

With `sidebar.preview` enabled (the default) the preview float follows the
cursor on its own: resting on a location or note row opens or refreshes it,
other rows hide it, and it closes when the sidebar loses focus. Set
`sidebar.preview = false` to fall back to the `p` peek that closes on the next
cursor move.

## Configuration

`setup()` validates every option immediately. Changes made while a flow is open
apply to the next session.

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `sidebar.width` | integer | `42` | Maximum popup width; must be at least 20 |
| `sidebar.side` | `"left"` or `"right"` | `"right"` | Editor edge the popup is pinned to |
| `sidebar.border` | string | `"rounded"` | One of `none`, `single`, `double`, `rounded`, `solid`, or `shadow` |
| `sidebar.icons` | boolean or table | `true` | `true` for Nerd Font icons, `false` for plain text, or per-icon overrides (including `icons.kinds`) |
| `sidebar.path` | string | `"relative"` | Location paths: `relative`, `filename`, or `shortened` |
| `sidebar.preview` | boolean | `true` | Preview float follows the sidebar cursor and closes on focus loss |
| `sidebar.indent` | integer | `1` | Accepted for configuration compatibility; the flat ledger does not indent by depth |
| `sidebar.test_paths` | string list | common test layouts | Lua patterns that classify a location as test code |
| `navigation.timeout_ms` | integer | `10000` | Per-network-stage timeout from 100 through 120000 milliseconds |
| `sidebar_keymaps.jump_or_toggle` | keymap or false | `"<CR>"` | Activate a location/note or toggle an action |
| `sidebar_keymaps.jump_stay` | keymap or false | `"o"` | Jump but keep focus in the sidebar |
| `sidebar_keymaps.run_action` | keymap or false | `"a"` | Jump to the node and pick an action to record |
| `sidebar_keymaps.show_callers` | keymap or false | `"u"` | Show or fetch callers for the contextual symbol |
| `sidebar_keymaps.show_callees` | keymap or false | `"d"` | Show or fetch calls from the contextual symbol |
| `sidebar_keymaps.refresh_callers` | keymap or false | `"U"` | Refresh callers from LSP |
| `sidebar_keymaps.refresh_callees` | keymap or false | `"D"` | Refresh calls from LSP |
| `sidebar_keymaps.preview` | keymap or false | `"p"` | Peek at the selected location |
| `sidebar_keymaps.delete` | keymap or false | `"x"` | Unlink an occurrence, delete a relation/history branch, or clear a note |
| `sidebar_keymaps.note` | keymap or false | `"n"` | Edit a location note |
| `sidebar_keymaps.save` | keymap or false | `"s"` | Save the flow |
| `sidebar_keymaps.load` | keymap or false | `"L"` | Load a flow |
| `sidebar_keymaps.toggle` | keymap or false | `"za"` | Toggle a relation section |
| `sidebar_keymaps.collapse_all` | keymap or false | `"zM"` | Collapse every relation section |
| `sidebar_keymaps.expand_all` | keymap or false | `"zR"` | Expand every relation section |
| `sidebar_keymaps.help` | keymap or false | `"?"` | Show the key reference |
| `sidebar_keymaps.close` | keymap or false | `{ "q", "<Esc>" }` | Close Voyager |
| `storage.resolve_uri` | function or nil | `nil` | Resolve a non-file URI to a valid loaded buffer |
| `storage.autosave` | boolean | `false` | Save dirty flows automatically on close, load, and quit |

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
: Preview float follows the sidebar cursor and closes on focus loss.

sidebar.indent
: Accepted for configuration compatibility; the flat ledger does not indent by depth.

sidebar.test_paths
: Lua patterns that classify a location as test code.

navigation.timeout_ms
: Per-network-stage timeout from 100 through 120000 milliseconds.

sidebar_keymaps.jump_or_toggle
: Activate a location/note or toggle an action; a string, string list, or `false`.

sidebar_keymaps.jump_stay
: Jump but keep focus in the sidebar; a string, string list, or `false`.

sidebar_keymaps.run_action
: Jump to the node and pick an action to record; a string, string list, or `false`.

sidebar_keymaps.show_callers
: Show or fetch callers for the contextual symbol; a string, string list, or `false`.

sidebar_keymaps.show_callees
: Show or fetch calls from the contextual symbol; a string, string list, or `false`.

sidebar_keymaps.refresh_callers
: Refresh callers from LSP; a string, string list, or `false`.

sidebar_keymaps.refresh_callees
: Refresh calls from LSP; a string, string list, or `false`.

sidebar_keymaps.preview
: Peek at the selected location; a string, string list, or `false`.

sidebar_keymaps.delete
: Unlink an occurrence, delete a relation/history branch, or clear a note; a string, string list, or `false`.

sidebar_keymaps.note
: Edit a location note; a string, string list, or `false`.

sidebar_keymaps.save
: Save the flow; a string, string list, or `false`.

sidebar_keymaps.load
: Load a flow; a string, string list, or `false`.

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
: Optional resolver from a non-file URI to a valid loaded buffer.

storage.autosave
: Save dirty flows automatically on close, load, and quit.

-->

A sidebar `keymap` is a string or non-empty string list. Mapping values set to
`false` are disabled. Enabled mappings in each group must have distinct,
non-empty normal-mode left-hand sides after Neovim keycode normalization.

## Appearance

Every part of a row carries a dedicated highlight group with a sensible
default link, overridable like any other group: `VoyagerHeader`,
`VoyagerDirty`, `VoyagerRequests`, `VoyagerSymbol`, `VoyagerVisited`,
`VoyagerAncestor`, `VoyagerPath`, `VoyagerActionLabel`, `VoyagerCount`,
`VoyagerIcon`, `VoyagerDisclosure`, `VoyagerDirectionUp`,
`VoyagerDirectionDown`, `VoyagerCurrent`, `VoyagerCurrentLine`,
`VoyagerStale`, `VoyagerNote`, `VoyagerFlash`, `VoyagerRelationFocus`,
`VoyagerRelationHeader`, `VoyagerRelationOrigin`, and
`VoyagerRelationTarget`. The current row gets a full-line highlight, every
location on the current node's path renders its symbol emphasized, and visited
locations render dimmed through `VoyagerVisited`. Moving the sidebar cursor
onto a symbol highlights every visible alias plus its direct relation headers,
origins, and targets. The `▲`/`▼` glyphs keep direction readable without color,
and `VoyagerFlash` briefly marks the source line after a sidebar jump.

Each location is prefixed with a badge for its symbol kind (class, interface,
record, method, and friends) resolved from the language server or treesitter;
override the glyphs through `sidebar.icons.kinds`.

`sidebar.path` trims location paths when the card gets crowded:
`"relative"` (default) shows the project-relative path, `"filename"` only the
file name, and `"shortened"` a `l/a/store.lua`-style abbreviation.

The projection is flat: symbols and relation headers keep a constant left edge
regardless of semantic depth. Ownership remains unambiguous because each header
includes its origin, such as `callers of Service.save` or
`calls from Service.save`.

## Exploring and branching

Navigate however you always do—your own mappings, Neovim's `gr*` defaults, or
a picker plugin. When a navigation request leaves the buffer you are editing,
Voyager concurrently records every unique normalized destination beneath a
relation row such as `implementations of …`, `usages of …`, or `callers of …`.
Successful empty responses remain visible as an action with zero results.
Destinations in test files gather beneath a `tests (N)` row that starts folded;
`<CR>` or `za` on it reveals them.

Once an action records its destinations, Voyager watches for the cursor to land
exactly on one of them in a normal source window—through a quickfix jump, a
picker, or any other navigation—and marks that destination as the flow's
current node. Later landings on the same action's destinations keep updating
the current node until a newer action runs or you pick a node in the sidebar.

Revisiting recorded ground never duplicates a location. A destination that
already exists anywhere in the flow—an ancestor you retrace, or an overlapping
result from two queries—is reused through an explicit relation edge. The edge
still appears under its origin, so reverse and converging call paths remain
visible. A manual jump onto an ancestor continues from that node instead of
recording a connector.

Unlinking an occurrence, or replacing a relation during refresh, removes only
that visible edge. If nothing else links the canonical location, Voyager keeps
it under an explicit `unlinked history` section, together with its notes and
explored relations. It stays navigable and can be deleted deliberately from
there instead of silently disappearing or continuing to inflate relation counts.

The flat ledger keeps call-flow order without accumulating indentation: actions
that surface callers appear above their origin, while definitions,
declarations, implementations, type definitions, and outgoing calls appear
below it.

Call-hierarchy recording follows the protocol's prepare step without
prompting: when a server returns several prepared items, Voyager records calls
for the first one while your own mapping keeps its usual behavior.

Select any location and press `u` for callers or `d` for calls from it. A cached
relation expands and focuses immediately; a missing one gets a stable loading
row while Voyager queries LSP from the row's persisted symbol-selection anchor.
Ordinary destinations use their resolved enclosing symbol; call-hierarchy rows
still jump to the recorded call site but use the protocol caller/callee item as
their query subject. If an anchored source line has changed, the request fails
safely instead of recording results for whichever symbol moved under the old
coordinate. Background queries do not jump a source window, change Voyager's
logical current node, or add newly loaded files to `:ls`. Repeating the same key
coalesces an in-flight request, failures remain retryable, and a successful
empty response is recorded as an authoritative `(0)` relation.
`U`/`D` refresh an existing relation: the old targets remain usable during the
request and on failure, while a complete success replaces them.

The existing tools remain available: `a` jumps to the selected node and offers
all seven actions in a picker, `o` jumps while keeping sidebar focus, `p` opens
a bordered preview, and `x` unlinks a selected relation occurrence without
erasing shared history. On a relation header it deletes that relation and moves
otherwise unlinked records to history; on an unlinked-history row it deletes
that stored branch; on a note it clears the note. Explicit unlinks and deletions
survive save merges. `:VoyagerExport` sends every resolvable location to the
quickfix list for `:cdo`-style follow-up work.

If the editor cursor no longer matches Voyager's logical current node when an
action starts, Voyager stages a `manual jump` connector for the actual source
location. The connector and LSP action are committed together only when the LSP
operation succeeds. Plain cursor movement is never recorded, and failed,
cancelled, unsupported, or superseded actions leave no synthetic persisted
relation.

## Notes

Press `n` on a location or its note row. The current note is prefilled through
`vim.ui.input`; submitting a trimmed non-empty line saves it, while submitting an
empty value removes it. Newline runs from custom input providers become spaces.
Cancelling leaves the note unchanged. Notes are persisted with their location
and can be useful for reminders such as “important for auth”.

## Saving, merging, and loading

Saving is explicit by default, and `storage.autosave = true` opts into saving
dirty flows automatically on close, load, and quit instead of prompting (the
prompt returns if an automatic save fails). Each project stores human-readable,
schema-versioned JSON under:

```text
<project-root>/.voyager/flows/<flow-name>-<root-hash>.json
```

Valid schema-v1 flows migrate automatically when read. Duplicate locations
from older concurrent merges are canonicalized without losing their notes or
relations, and the next save writes the strict schema-v2 representation.

There is one logical saved flow per root identity. Before every save, Voyager
re-reads the latest valid revision and recursively merges actions, destinations,
relation edges, notes, collapsed state, and the current node. New and saved-only
records are retained unless the active session explicitly unlinked or deleted
them. The merged JSON is flushed to a unique sibling temporary file and
atomically renamed; sequential saves therefore merge the latest completed write.
Truly simultaneous processes are last-rename-wins. The `.voyager` directory is
project-local and may be committed to version control.

`:VoyagerLoad` or sidebar `L` opens a latest-first project picker. Invalid files
are reported and skipped. Loading a flow replaces the current one only after any
dirty-flow decision completes. Missing or out-of-range destinations remain in
the ledger as stale rows; Voyager does not silently delete them.

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

Voyager owns one process-wide session and one NUI popup. `:VoyagerOpen` stages
a new session only when none is active; repeated opens focus the existing one.
Until the first navigation the sidebar shows a waiting placeholder, there is
nothing to save, and closing never prompts. The popup remounts across tabs and
valid resizes without creating or resizing source splits.

Closing cancels pending LSP requests and late interaction tokens, removes the
session autocmd group, and closes only Voyager-owned windows. Intentional
buffers, cursors, jumplist/tagstack entries, and quickfix or location lists
created while exploring are not rewound.

`VimLeavePre` performs teardown without a prompt, so explicitly save anything
you want to keep before exiting Neovim — or set `storage.autosave = true` to
have quitting save the flow for you.

Run `:checkhealth voyager` to verify the Neovim version, `nui.nvim`, and
storage writability. For statuslines, `require("voyager").status()` returns
`nil` or `{ name, dirty, locations, requests }` for the active flow.

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
