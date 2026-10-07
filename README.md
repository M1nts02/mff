# mff

A native macOS GUI fuzzy finder with a Spotlight-style interface and fzf-style
behaviour. Built with Swift and xmake.

## Modes

- **stdin** — no path/type argument (or `--stdin`): read lines from stdin,
  fzf-style.
- **files** — a path / type / `--name` is given: search the filesystem
  (mdfind-style). `⌘G` changes the search folder with path completion.
- **content** — `--content`: like file search, but the query is also matched
  against the text contents of regular files and audio metadata (title / artist /
  album). Matching starts one second after you stop typing, then results stream
  in as the tree is scanned.
- **apps** — `--app`: search applications by name (Launchpad-style); launches on
  Enter when interactive.

## Features

- Embedded preview: Quick Look for documents / images / folders, a player with
  cover art for audio / video, and plain text for lyrics / subtitles. FLAC/OGG/Opus
  tags and MKV/WebM covers are read natively.
- Drag & drop: drag results out to Finder to move/copy them, or onto an app to
  open them (marked rows are dragged together).

## Usage

### Build

```bash
xmake b
```

### Package (universal zip)

```bash
./package.sh
# dist/mff-<version>-macosx-universal.zip
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
mff --content ~/notes TODO         # files whose contents contain "TODO"
```

### Preview

- Documents / images / folders — Finder-style Quick Look.
- Lyrics / subtitles (`.lrc`, `.srt`, `.ass`, `.vtt`, …) — shown as plain
  text in the preview pane.
- Audio — embedded player with cover art and title / artist / album captions
  (search hits are highlighted in content mode). FLAC, OGG and Opus tag/cover
  metadata is parsed natively (AVFoundation does not expose it); other formats
  fall back to AVFoundation metadata.
- Video — the built-in player for containers AVFoundation can decode (mp4, mov,
  …); MKV/WebM show their embedded cover image (a Matroska attachment) or a
  placeholder.
- `⌘↩` toggles auto-play of audio/video previews.

### Search

Terms are separated by **Tab** (press Tab to insert a separator); spaces are
ordinary characters. Every term must match (AND) somewhere in the **whole path**.

`text` fuzzy · `'text` exact · `.ext` extension · `^pre` / `suf$` name start/end · `!x` exclude

In content mode (`--content`) the path/name is matched first; only if a term
does not match the path is it looked up (case-insensitively) in the contents or,
for audio, in the title / artist / album. Matching does not run while you type —
it starts one second after the input stops, then streams results in. `.ext` and
`^`/`$` still apply to the file name.

### File types

`-t` / `--type` accepts a category name or an explicit extension (`.mp3`,
`tar.gz`, …), comma-separated. Categories and their extensions:

| Category | Extensions |
| --- | --- |
| `image` | jpg, jpeg, png, gif, heic, heif, webp, tiff, tif, bmp, svg, ico, raw, cr2, nef, arw, dng, psd, ai, eps, avif, jp2, jxl |
| `video` | mp4, mov, m4v, avi, mkv, webm, flv, wmv, mpg, mpeg, 3gp, mts, m2ts, ts, ogv, vob |
| `audio` | mp3, wav, aac, m4a, flac, ogg, wma, aiff, aif, alac, opus, mid, midi, ape, amr |
| `document` | pdf, doc, docx, xls, xlsx, ppt, pptx, pages, numbers, key, rtf, odt, ods, odp, epub, mobi |
| `text` | txt, md, markdown, csv, tsv, json, xml, yaml, yml, toml, ini, plist, html, htm, css, js, ts, jsx, tsx, swift, m, mm, c, h, cpp, hpp, cs, java, kt, kts, py, rb, go, rs, php, sh, zsh, bash, fish, sql, log, conf, cfg, gitignore, rst, tex, lua, lrc, krc, qrc, srt, ass, ssa, vtt, sub, sbv, smi, sami, ttml, dfxp, scc |
| `archive` | zip, tar, gz, tgz, bz2, tbz, xz, txz, 7z, rar, dmg, pkg, iso, deb, rpm, zst, lz, lz4 |
| `folder` | any directory |
| `app` | app, bundle, framework, xcodeproj, playground (use `--app`) |

`text` includes source code, config files, lyrics (`.lrc`, `.krc`, `.qrc`) and
subtitles (`.srt`, `.ass`, `.ssa`, `.vtt`, `.sub`, `.sbv`, `.smi`, `.sami`,
`.ttml`, `.dfxp`, `.scc`). Lyrics and subtitles are previewed as plain text.

### Options

| Option | Description |
| --- | --- |
| `PATH` / `-p, --path DIR` | Directory to search (repeatable; default: cwd). `--onlyin` is an alias |
| `-t, --type TYPE` | Type filter: category or extension (see **File types** below), comma-separated |
| `--app` | Search applications by name (Launchpad-style; launches on Enter when interactive) |
| `--content` | Content mode: also match text contents and audio title / artist / album |
| `--max-filesize SIZE` | Content mode: don't search the contents of files larger than SIZE (`K`/`M`/`G`, 1024-based, or bytes; `0` = no limit; default `20M`) |
| `--stdin` | Force stdin mode: read items from stdin even when a path/type argument is given |
| `-q, --query TEXT` | Initial query |
| `--enter path\|open\|reveal` | Enter action (default `path`); `--open` = `--enter open` |
| `--multi` | Allow multi-select (not with `--app`); `⇧↑/↓` extends, `⌘M` marks, `⌘⇧M` clears marks, `⌘⇧A` marks all |
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

### Bottom bar

- Left: `Mark` / `Clear Marks` (multi-select, same as `⌘M` / `⌘⇧M`), then
  `Open` / `Reveal in Finder` / `Return` (same as `⌘O` / `⌘R` / `↩`).
- Right: `⌘G` folder picker (change the search folder; the list goes full width
  and the preview is hidden while picking) and, for file/content search, the file-type
  popup (same as `⌘T`).

## Credits

mff references and is inspired by:

- [choose](https://github.com/chipsenkbeil/choose) — a native macOS GUI fuzzy
  matcher that reads a list from stdin.
- [fzf](https://github.com/junegunn/fzf) — the command-line fuzzy finder whose
  behaviour mff follows.
