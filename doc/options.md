# Options & keyboard

## Options

| Option | Description |
| --- | --- |
| `PATH` / `-p, --path DIR` | Directory to search (repeatable; default: cwd). `--onlyin` is an alias |
| `QUERY` | Any positional that is not an existing directory or an explicit type token (`.mp3`, `kind:video`, `image,video`) is the initial query |
| `-t, --type TYPE` | Type filter: category or extension (see [search.md](search.md#file-types)), comma-separated |
| `--app` | Search applications by name (Launchpad-style; launches on Enter when interactive) |
| `--content` | Content modifier (text): also match text file contents (read live, never indexed). Needs a file search target or `--stdin-files` |
| `--binary` | Content modifier (binary): also match binary-file metadata (audio, video incl. MKV/WebM, image EXIF); index-served. Needs a file search target or `--stdin-files` |
| `--max-filesize SIZE` | With `--content`: don't search the contents of files larger than SIZE (`K`/`M`/`G`, 1024-based, or bytes; `0` = no limit; default `20M`) |
| `--stdin [MODE]` | Force stdin mode. Optional `MODE`: `lines` (raw strings, default) or `files` (each line is a path, browsed like a file; `-t`/`--name` filter them) |
| `--stdin-files` | Shorthand for `--stdin files` |
| `-q, --query TEXT` | Initial query |
| `--enter path\|open\|reveal` | Enter action (default `path`); `--open` = `--enter open` |
| `--exclude GLOB` | Exclude paths matching GLOB from results (repeatable; any mode, indexed or live) |
| `--config PATH` | Use `PATH` instead of `~/.config/mff/config.toml` (`$MFF_CONFIG` also overrides it) |
| `--no-config` | Ignore `config.toml` entirely |
| `--no-index` | Never use the index daemon; always walk the filesystem live |
| `--index-daemon` | Run the resident index process instead of the GUI (see [index.md](index.md)) |
| `--rebuild-index` | Rebuild the index before serving (with `--index-daemon`), or rebuild and exit |
| `--multi` | Allow multi-select (not with `--app`); `⇧↑/↓` extends, `⌘M` marks, `⌘⇧M` clears, `⌘⇧A` marks all |
| `--autoplay` | Auto-play audio/video previews (default off; `⌘↩` toggles) |
| `--no-preview` / `--no-icons` | Disable the preview pane / file icons |
| `--hidden` | Include hidden files (default: skip) |
| `-0` / `-i` / `-1` / `-m` | NUL-separated / print index / auto-select single match / return query on no match |
| `-n ROWS` / `-w WIDTH` | Visible rows / list width |
| `-h` / `-v` | Help / version |
| `--self-test` | Run the matcher self-test headlessly and exit (0 = all passed); useful in CI / over ssh |

Matching is debounced: ordinary and index-backed searches start 0.5 s after you
stop typing; `--content` / `--binary` searches start 1 s after. An initial query
given with `-q` is applied immediately.

`-1` and Enter always act on the **final** result set: while results stream in
(index or live), the list is still growing, so Enter waits and `-1` only fires
once loading has finished and exactly one item matches.

When a query only **extends** the previous one (extra characters, no new
operators such as `!`, `^`, `$`, `.`), the search starts from the previous
results: already-filtered items are not re-examined, while the remaining ones are
re-matched so scores and highlights stay accurate. Shorter or unrelated edits
rescan everything.

## Subcommands

```bash
mff index rebuild [--volume PATH] | clean | stop | status
```

## Keyboard

| Key | Action |
| --- | --- |
| `↑↓`, `PgUp`/`PgDn`, `Ctrl+P/N/J/K` | Move selection |
| `⌘↩` | Play / toggle auto-play of audio/video previews |
| `Tab` | Insert a search-term separator |
| `↩` | Return the selected path |
| `⌘O` / `⌘R` | Open / reveal in Finder (reveal disabled while multi-selected) |
| `⇧↑/↓` | Extend the selection (Finder-style, `--multi`) |
| `⌘M` | Mark/unmark the current file (`--multi`) |
| `⌘⇧M` | Clear all marks (`--multi`) |
| `⌘⇧A` | Mark all rows (`--multi`) |
| `⌘G` | Change the search folder (⌘1-9/Tab complete, `↩` confirm) |
| `⌘T` | Open the file-type selector (file/content search) |
| `⌘1`–`⌘9` | Select the Nth row (rows 1–9 show their number) |
| `esc` / `ctrl+c` | Cancel |

While the folder picker is open (`⌘G`): `↑↓` navigate, `Tab` / `→` / left-click
completes (descends into) the highlighted folder, `⌘1`–`⌘9` completes the Nth,
`↩` confirms the path, `esc` cancels.

## Bottom bar

- Left: `Mark` / `Clear Marks` (multi-select, same as `⌘M` / `⌘⇧M`), then
  `Open` / `Reveal in Finder` / `Return` (same as `⌘O` / `⌘R` / `↩`).
- Right: folder picker button (same as `⌘G`; the list goes full width and the
  preview is hidden while picking) and, for file/content search, the file-type
  popup (same as `⌘T`).
- The menu-bar item (always present) offers **Show mff** (`⌘O`) and **Quit mff**
  (`⌘Q`). Closing the window hides mff; switching to another app quits it.

## Configuration

Configuration is a plain file, `~/.config/mff/config.toml` (no subcommands):
see [config.md](config.md) for every key and
[../config.example.toml](../config.example.toml) for a fully annotated example.
`--config PATH` / `$MFF_CONFIG` change the path, `--no-config` ignores it.
Unknown keys are reported on stderr at startup.
