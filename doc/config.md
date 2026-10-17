# Configuration

mff reads an optional `~/.config/mff/config.toml` (a plain data file — keep it
in dotfiles / version control). It is **not** created automatically: copy
[../config.example.toml](../config.example.toml) and uncomment what you need.
Without it, mff behaves with defaults.

mff is configured **entirely from `config.toml`** — there is no settings panel,
so the file stays the single source of truth. CLI flags override the file when
both are given. `--config PATH` / `$MFF_CONFIG` override the path; `--no-config`
ignores the file entirely. A malformed file prints a clear error and mff still
starts with the defaults.

Path values (top-level `exclude`, `[index] volumes` / `external_volumes` path
lists) accept a leading `~`, `${HOME}` or `$HOME`.

Unknown keys or tables are reported on stderr when mff starts (a file with
mistakes still loads, with the offending entry ignored).

## Exclude (all modes)

```toml
exclude = ["**/node_modules", "~/.cache", "*.tmp"]
```

Supported patterns: `**/name` or `name` (any path component), `**/name/**`
(subtree), `*.ext` (by extension), and a multi-component path suffix. A general
`foo*` prefix glob is not supported.

`exclude` filters **results** in every mode (files, content, binary,
`--stdin files`), whether the index is used or a live walk runs.
`--exclude GLOB` (repeatable) adds patterns for one run. To also keep paths out
of the **index**, use [`[index] exclude`](index.md).

## UI

```toml
[ui]
icons = true              # file icons (--no-icons / --icons override)
preview = true            # preview pane (--no-preview / --preview override)
rows = 10                 # visible rows (-n overrides)
width = 720               # list width (-w overrides)
keybinding = "cmd+space"  # global hotkey; keeps mff resident in the menu bar
```

mff always has a menu-bar item (Show ⌘O / Quit ⌘Q): closing the window hides
it, and switching to another app quits mff. With `keybinding` set the item also
keeps mff resident and the hotkey toggles the window. `rows` must be > 0 and
`width` >= 400 to take effect.

## Icon overrides

Override icons per extension; the value may be an app name, a bundle id, or a
path:

```toml
[icons.overrides]
rs  = "dev.rust"
mp3 = "Music"
```

## Index

See [index.md](index.md).

## Example

See [../config.example.toml](../config.example.toml) for a fully annotated
example covering every supported key.
