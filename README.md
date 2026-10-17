# mff

A native macOS GUI fuzzy finder with a Spotlight-style interface and fzf-style
behaviour. Built with Swift and xmake.

```bash
mff                                # search the current directory
ls | mff                           # pick from stdin
mff ~/Music .mp3                   # find .mp3 files under ~/Music
mff --app                          # app launcher
mff ~/notes --content TODO         # files whose text contains "TODO"
mff ~/Music --binary neon          # audio/video/image whose metadata matches
mff --index-daemon                 # optional: start the resident index
brew services start mff            # ...or run it as a login service
```

## Features

- **Modes**: files (path / type / no args = current dir), stdin (fzf-style),
  and apps; pipe anything (zoxide, mdfind, any script) in with `--stdin`.
- **Content modifiers**: `--content` matches text file contents live;
  `--binary` matches binary metadata (audio/video tags, image EXIF).
- **Preview**: Quick Look, media player with cover art, plain text for
  lyrics/subtitles; FLAC/OGG/Opus tags and MKV/WebM covers parsed natively.
- **Optional index daemon**: per-volume, FSEvents-incremental, survives restarts
  and disk eject, re-reads `config.toml` while running; falls back to a live walk
  whenever unavailable.
- Config lives entirely in `~/.config/mff/config.toml` (no GUI settings panel,
  no subcommands): see [doc/config.md](doc/config.md).

## Documentation

| Document | Contents |
| --- | --- |
| [doc/usage.md](doc/usage.md) | Build, package, install, examples, preview |
| [doc/search.md](doc/search.md) | Query syntax, file-type categories, content/binary matching |
| [doc/options.md](doc/options.md) | All CLI options, keyboard shortcuts, bottom bar |
| [doc/config.md](doc/config.md) | `config.toml` reference: `[ui]`, icons, exclude, `[index]` |
| [doc/index.md](doc/index.md) | Index daemon: lifecycle, volumes, commands, tuning |
| [config.example.toml](config.example.toml) | Heavily annotated example config |

## Quick start

```bash
xmake b                 # build -> build/macosx/<arch>/release/mff
./package.sh            # universal zip -> dist/
brew install m1nts02/tap/mff
```

Bump `VERSION` at the top of `package.sh` to release; it is injected into the
binary (`mff --version`) and used for the package name.

## Credits

mff references and is inspired by:

- [choose](https://github.com/chipsenkbeil/choose) — a native macOS GUI fuzzy
  matcher that reads a list from stdin.
- [fzf](https://github.com/junegunn/fzf) — the command-line fuzzy finder whose
  behaviour mff follows.
