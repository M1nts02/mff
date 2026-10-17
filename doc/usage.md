# Usage

## Build

```bash
xmake b
```

## Package (universal zip)

```bash
./package.sh
# dist/mff-<version>-macosx-universal.zip
```

Bump `VERSION` at the top of `package.sh` to release a new version; it is
injected into the binary (`mff --version`) and used for the package name.

## Install

```bash
brew install m1nts02/tap/mff
```

## Examples

```bash
mff                                # search the current directory (tty)
ls | mff                           # fzf: pick from stdin
ls | mff --stdin                   # same, forced
zoxide query -l | mff --stdin files  # browse zoxide dirs as files
mdfind kMDItemFSName=foo | mff --stdin files   # browse mdfind results
mff ~/Music .mp3                   # find .mp3 files under ~/Music
mff -p ~/Downloads -t video,image  # videos/images in Downloads
mff --app                          # app search (Enter launches)
mff -p ~/Downloads --enter reveal  # Enter reveals in Finder
mff ~/notes --content TODO         # files whose text contents contain "TODO"
mff ~/Music --binary neon          # audio whose metadata matches "neon"
mff ~/x --content --binary term    # text OR binary metadata
mff --content --stdin files        # piped paths, search their text contents
```

## Preview

- Documents / images / folders — Finder-style Quick Look.
- Lyrics / subtitles (`.lrc`, `.srt`, `.ass`, `.vtt`, …) — shown as plain text
  in the preview pane.
- Audio — embedded player with cover art and title / artist / album captions
  (search hits are highlighted with `--content`/`--binary`). FLAC, OGG and Opus
  tag/cover metadata is parsed natively (AVFoundation does not expose it); other
  formats fall back to AVFoundation metadata.
- Video — the built-in player for containers AVFoundation can decode (mp4, mov,
  …); MKV/WebM show their embedded cover image (a Matroska attachment) or a
  placeholder.
- `⌘↩` toggles auto-play of audio/video previews.

Previews work in file, content and `--stdin files` search (app bundles use
Quick Look). `--app` search is a compact launcher without a preview pane.
