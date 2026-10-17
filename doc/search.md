# Search

## Modes

- **files** — run with **no arguments** and mff searches the **current
  directory** (like `fzf`) when stdin is a terminal; if stdin is a pipe it reads
  the piped lines instead. Pass a path / type / `--name` to search elsewhere
  (mdfind-style). `⌘G` changes the search folder with path completion.
- **stdin** — `--stdin` reads lines from stdin, fzf-style. With `--stdin files`
  each line is treated as a filesystem path and browsed like a file result
  (icons, Quick Look preview, drag-out, open/reveal; app bundles are handled as
  files) — handy with `zoxide` or `mdfind`. `~` and relative paths are expanded,
  and `-t` / `--name` filter the piped paths. Use `--stdin` (or `--stdin files`)
  to force reading a pipe. Input must be newline-separated (`mdfind -0` output
  is not split).
- **content modifiers** — `--content` and/or `--binary` layer onto a file search
  (a PATH / TYPE / `--name`) or `--stdin files`; they are **not** a mode on their
  own. `--content` also matches the **text contents** of regular files (read
  live); `--binary` (alias `--bcontent`) also matches **binary-file metadata** —
  audio title/artist/album, video title/artist/description (MKV/WebM tags parsed
  natively), and image EXIF (camera make/model + capture date) — servable from
  the index. Both may be combined
  (path OR text OR binary metadata). Matching waits until you stop typing
  (0.5 s; content/binary searches wait 1 s), then results stream in.
- **apps** — `--app`: search applications by name (Launchpad-style); launches on
  Enter when interactive.

## Query syntax

Terms are separated by **Tab** (press Tab to insert a separator); spaces are
ordinary characters. Every term must match (AND) somewhere in the **whole path**.

| Syntax | Meaning |
| --- | --- |
| `text` | fuzzy match (letters in order, anywhere in the path) |
| `'text` | exact substring |
| `.ext` | file extension (multi-part like `.tar.gz` works) |
| `^pre` | file name starts with `pre` |
| `suf$` | file name ends with `suf` |
| `!x` | exclude anything matching `x` |

In `--stdin files` mode the piped paths are matched against the whole path
(just like file search); `-t` / `--type` and `--name` are applied while reading
the paths. App bundles such as `.app` are ordinary file results with their real
bundle icon.

With `--content` / `--binary` the path/name is matched first; only if a term
does not match the path is it looked up (case-insensitively) in the text contents
(`--content`) or the binary metadata (`--binary`). Matching does not run while
you type — it starts after the input stops, then streams results in.
`.ext` and `^`/`$` still apply to the file name. These modifiers also work with
`--stdin files` (the piped paths' contents are read live).

Typing more characters is incremental: the new search starts from the previous
matches (an item that failed a shorter query cannot match a longer one), and only
surviving items are scored again. Deleting characters, or adding an operator
(`!`, `^`, `$`, `.`), triggers a full rescan.

## File types

`-t` / `--type` accepts a category name or an explicit extension (`.mp3`,
`tar.gz`, …), comma-separated. As a bare positional, a type must be explicit:
`.mp3`, `*.mp3`, `tar.gz`, `kind:video`, or category names (`image`,
`image,video`). Any other bare word is treated as the query, so
`mff agent -p ~/src` searches for "agent" instead of filtering by the extension
`.agent`.

Categories and their extensions:

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

Note: MKV/WebM are classified as `video` by extension.
