# mff

A native macOS GUI fuzzy finder with a Spotlight-style interface and fzf-style
behaviour. Built with Swift and xmake.

- No arguments: read lines from stdin and fuzzy-select one, like fzf.
- With a path / file type: search the filesystem; arguments follow `mdfind`.
- Embedded preview: Quick Look for documents / images / folders, a player with
  cover art for audio / video.
- `--app`: search applications, like Launchpad.

## Usage

### Build

```bash
xmake b
# binary: build/macosx/arm64/release/mff
```

### Package (universal zip)

```bash
./package.sh
# dist/mff-<version>-macosx-universal.zip  (arm64 + x86_64)
```

Bump `VERSION` at the top of `package.sh` to release a new version; it is
injected into the binary (`mff --version`) and used for the package name.

### Install

```bash
brew install m1nts02/tap/mff
```

### Examples

```bash
ls | mff                           # fzf: pick from stdin
mff ~/Music .mp3                   # find .mp3 files under ~/Music
mff -p ~/Downloads -t video,image  # videos/images in Downloads
mff --app                          # app search (Enter launches)
mff -p ~/Downloads --enter reveal  # Enter reveals in Finder
```

### Search

Terms are separated by **Tab** (press Tab to insert a separator); spaces are
ordinary characters. Every term must match (AND) somewhere in the **whole path**.

`text` fuzzy · `'text` exact · `.ext` extension · `^pre` / `suf$` name start/end · `!x` exclude

### Options

| Option | Description |
| --- | --- |
| `PATH` / `-p, --path DIR` | Directory to search (repeatable; default: cwd). `--onlyin` is an alias |
| `-t, --type TYPE` | Type filter: category (image/video/audio/document/text/archive/folder) or extension (`.mp3`), comma-separated |
| `--app` | Search applications by name (Launchpad-style; launches on Enter when interactive) |
| `-q, --query TEXT` | Initial query |
| `--enter path\|open\|reveal` | Enter action (default `path`); `--open` = `--enter open` |
| `--autoplay` | Auto-play audio/video previews (default off; `⌘↩` toggles) |
| `--no-preview` / `--no-icons` | Disable the preview pane / file icons |
| `--hidden` | Include hidden files (default: skip) |
| `-0` / `-i` / `-1` / `-m` | NUL-separated / print index / auto-select single match / return query on no match |
| `-n ROWS` / `-w WIDTH` | Visible rows / list width |
| `-h` / `-v` | Help / version |

### Keyboard

| Key | Action |
| --- | --- |
| `↑↓`, `PgUp`/`PgDn`, `Ctrl+P/N/J/K` | Move selection |
| `⌘↩` | Play / toggle auto-play of audio/video previews |
| `Tab` | Insert a search-term separator |
| `↩` | Return the selected path |
| `⌘O` / `⌘R` | Open / reveal in Finder |
| `⌘T` | Open the file-type selector (file search) |
| `⌘1`–`⌘9` | Select the Nth row (rows 1–9 show their number) |
| `esc` / `ctrl+c` | Cancel |

### Bottom bar

- Left: `Open` / `Reveal in Finder` / `Return` (same as `⌘O` / `⌘R` / `↩`).
- Right (file search): file-type popup, same as `⌘T`.

## Credits

mff references and is inspired by:

- [choose](https://github.com/chipsenkbeil/choose) — a native macOS GUI fuzzy
  matcher that reads a list from stdin.
- [fzf](https://github.com/junegunn/fzf) — the command-line fuzzy finder whose
  behaviour mff follows.
