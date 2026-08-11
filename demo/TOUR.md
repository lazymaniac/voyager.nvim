# Voyager feature tour

Run once: `make deps`, then start the demo with:

```sh
nvim -u demo/init.lua
```

A tiny fixture LSP server (bundled, deterministic) serves the sample project,
so every step below works without installing a language server. `<Space>` is
the leader. Steps are ordered so each feature builds on the previous one.

| # | Do this | What you should see |
| --- | --- | --- |
| 1 | `<Space>vv` | A compact floating card top-right: colored header, `● main` current row with a full-line highlight. Statusline shows `Voyager: main · 1 locations`. |
| 2 | `gri` (Neovim's own implementation key) | The native quickfix opens (Voyager did not touch the key). The card grows: `▾ ▼  implementations (2)` below `main` — `▼` marks a callee group, the glyph before the label is the per-action icon. |
| 3 | `:cc 2`, then `:cclose` | The landed row becomes current (`●` + line highlight moves; statusline updates). The target line flashes briefly on sidebar jumps too. |
| 4 | With the cursor on `save`, press `grr` | A `▸ ▲  references (…)` group renders **above** `save` — callers sit on top, callees below: call-flow order. Symbols on the current node's path are bold (ancestor emphasis). |
| 5 | `<Space>vf`, move onto a location row, `p` | A preview float opens beside the card with syntax highlighting and the target line marked. Any cursor move closes it. |
| 6 | `?` | The key reference overlay. |
| 7 | On a location row: `o` | The source window jumps there (watch the flash) but focus stays in the sidebar. |
| 8 | On a location row: `a`, pick `references` | Voyager jumps to that node and records the picked action beneath it — exploration driven entirely from the sidebar. |
| 9 | On a row: `n`, type a note | A `✎`-style note line appears under the location (own highlight). |
| 10 | On a branch you dislike: `x` | The subtree disappears. Delete a note row to clear just the note. Save later — the pruned branch does **not** come back from disk. |
| 11 | `zM`, then `zR` | Collapse and expand every action at once; the card shrinks and grows with the content. |
| 12 | `s` | Saves the flow (`*` disappears from the header and statusline). |
| 13 | Back in code: `gd` on a symbol you came from | Reverse route: the tree does not grow; landing back on the ancestor just moves `●` up the existing path. |
| 14 | `:VoyagerExport`, then `:copen` | Every resolvable location in a fresh quickfix list. |
| 15 | `:checkhealth voyager` | Version, nui.nvim, LspRequest, and storage checks. |
| 16 | `q` in the sidebar | Prompt to save/discard (root-only flows close silently). Restart with `VOYAGER_DEMO_AUTOSAVE=1 nvim -u demo/init.lua` and closing a dirty flow saves without asking. |

Variants worth a second run:

```sh
VOYAGER_DEMO_ICONS=text nvim -u demo/init.lua        # plain-text markers, no Nerd Font needed
VOYAGER_DEMO_PATH=shortened nvim -u demo/init.lua    # l/m/store.lua-style paths
```

The automated proof for all of this is `make test` (173 unit + e2e tests).
