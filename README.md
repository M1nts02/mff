# mff

A native macOS GUI fuzzy finder with a Spotlight-style interface and fzf-style
behaviour. Built with Swift and xmake.

- No arguments: read lines from stdin and fuzzy-select one, like fzf. `--stdin`
  forces stdin mode even when a path/type argument is given.
- With a path / file type: search the filesystem; arguments follow `mdfind`.
  `⌘G` changes the search folder with path completion.
- Embedded preview: Quick Look for documents / images / folders, a player with
  cover art for audio / video. FLAC/OGG/Opus tags and MKV/WebM cover art are
  read natively.
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

### Preview

- Documents / images / folders — Finder-style Quick Look.
- Audio — embedded player with cover art. FLAC, OGG and Opus tag/cover metadata
  is parsed natively (AVFoundation does not expose it); other formats fall back
  to AVFoundation metadata.
- Video — the built-in player for containers AVFoundation can decode (mp4, mov,
  …); MKV/WebM show their embedded cover image (a Matroska attachment) or a
  placeholder.
- `⌘↩` toggles auto-play of audio/video previews.

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
| `--stdin` | Force stdin mode: read items from stdin even when a path/type argument is given |
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
| `⌘G` | Change the search folder (⌘1-9/Tab complete, `↩` confirm) |
| `⌘T` | Open the file-type selector (file search) |
| `⌘1`–`⌘9` | Select the Nth row (rows 1–9 show their number) |
| `esc` / `ctrl+c` | Cancel |

While the folder picker is open (`⌘G`): `↑↓` navigate, `Tab` / `→` / left-click
completes (descends into) the highlighted folder, `⌘1`–`⌘9` completes the Nth,
`↩` confirms the path, `esc` cancels.

### Bottom bar

- Left: `Open` / `Reveal in Finder` / `Return` (same as `⌘O` / `⌘R` / `↩`).
- Right: `⌘G` folder picker (change the search folder; the list goes full width
  and the preview is hidden while picking) and, for file search, the file-type
  popup (same as `⌘T`).

## Credits

mff references and is inspired by:

- [choose](https://github.com/chipsenkbeil/choose) — a native macOS GUI fuzzy
  matcher that reads a list from stdin.
- [fzf](https://github.com/junegunn/fzf) — the command-line fuzzy finder whose
  behaviour mff follows.
