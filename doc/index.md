# Index (optional accelerator)

File search can stream from a resident **index daemon** instead of walking the
filesystem, which makes repeated searches over large trees fast. It is entirely
optional — without it mff walks live.

```bash
mff --index-daemon                   # start the resident index process
mff --index-daemon --rebuild-index   # rebuild from scratch first
mff --no-index                       # force a live walk even while a daemon runs
```

A plain `mff` **auto-detects** the daemon: if one is running (and `enabled` is
true), file search uses the index; otherwise it falls back to a live walk. If the
daemon disappears mid-session, mff switches back to a live walk automatically
(checked at most once every few seconds).

## Commands

```bash
mff index status                        # daemon + per-volume state; lists configured roots not indexed
mff index rebuild                       # rebuild every configured volume
mff index rebuild --volume /Volumes/X   # rebuild just that volume
mff index stop                          # stop a running daemon (SIGTERM)
mff index clean                         # delete all index files
```

### Running it as a login service

`brew services start mff` runs `mff --index-daemon` as a launchd job for the
logged-in user (state and config are per-user). Two consequences:

- The job starts at login, possibly **before external disks are mounted**. The
  daemon picks them up when they mount (and on the next search if the mount
  notification is missed), re-checks the config on every connection and app
  switch, and resumes watching after sleep — no restart needed.
- Config edits made after the job started are picked up the same way; check
  `mff index status` if a disk still does not show up.

Only **one** daemon runs at a time: starting a second one detects the running
instance (exclusive lock file) and exits immediately.

## How it stays correct

- **Per-volume shards**: `~/Library/Application Support/mff/index/manifest.json`
  plus `vol-<uuid>#<root>.idx` (immutable base), `...ovl` (incremental overlay)
  and `...idx.meta2.json` (per-file cache used by rebuilds). A volume that is not
  ready is skipped and reported as `partial`.
- **FSEvents checkpoints**: event IDs are persisted and replayed after a restart,
  so changes made while the daemon was down are picked up automatically.
- **Disk eject/remount**: an ejected volume's entries disappear immediately
  (the root stops existing, which is checked on every search, so even an
  unclean eject cannot leave them listed); a remounted disk reloads its kept
  shard and resumes FSEvents from the checkpoint instead of re-walking. If a
  mount notification is missed (disk images, some remounts), configured roots
  that are mounted but not being served are adopted on the next search/watchdog
  tick. Shards are keyed by mount point, so the same disk coming back on the
  same path reuses its index. Mount/unmount only affects that volume.
- **Incremental**: creates/deletes/renames are reflected within ~0.2 s; a large
  overlay folds back into a fresh base index.
- **Never goes stale on its own**: the FSEvents stream keeps running while a
  base is rebuilt (previously each rebuild stopped it, so a multi-minute rebuild
  could end with the volume unwatched and the index silently frozen). Changes
  seen during a build are re-applied from the same directory diff once it
  finishes, and a rebuild request that arrives mid-build is queued.
- **Rebuilds are cheap**: the previous build's binary flags and media metadata
  are cached (`.meta2.json`) keyed by size + mtime, so a rebuild only re-opens
  files that are new or changed (home tree with ~150k entries: ~6 s instead of
  ~90 s).
- **Watchdog**: hourly, on every app switch and after waking from sleep, a
  shard whose FSEvents checkpoint has fallen far behind (or whose stream died)
  is re-watched, and rebuilt if watching cannot be restored.
- **Sleep & shutdown**: the debounced overlay writes are flushed immediately
  before the Mac sleeps and when the daemon receives SIGTERM (`index stop`, logout,
  shutdown), so nothing in the 2 s debounce window can be lost to a power loss
  during sleep.
- **Versioning**: `manifest.json` records the mff version that built the index
  (`appVersion`). Upgrading mff therefore rebuilds the whole index on the next
  daemon start (or `index rebuild`), and `index status` shows which version
  built it and whether a rebuild is pending. On-disk layout changes are handled
  too: a shard written with a different `formatVersion` is unreadable and is
  rebuilt.
- **Fallback**: if the daemon is missing or a volume is not ready, mff walks live
  instead of showing an empty list.

## Configuration

```toml
[index]
enabled = true            # may a plain mff use the daemon? (--no-index overrides)
volumes = "auto"          # built-in: "auto" (home) | "none" | a path list
external_volumes = "none" # external disks: "none" (default) | "all" | a path list
exclude = ["**/node_modules", "**/DerivedData", "**/.git"]
```

- `exclude` here keeps paths **out of the index** (they are still found by a live
  walk unless also in the top-level `exclude`).
- External volumes are **not** indexed by default; list them in
  `external_volumes` or use `all`.
- The config is **re-read while the daemon runs**: editing `config.toml` (adding
  a disk, changing excludes) is applied on the next daemon activity (any
  connection — `index status`, a search) or the next app switch, with no
  restart. Roots that are removed stop being served immediately (their shard
  files are kept); new roots that are mounted are built in the background.
- `index status` lists every configured root the daemon does **not** serve and
  whether it is mounted — the quickest check when a disk is not searchable.
- Filesystems without FSEvents (exFAT/NTFS) are still indexed but cannot be kept
  fresh live — refresh with `index rebuild`.
- In index mode `-p/--path` does not re-walk: the index covers the configured
  volumes and the path just **restricts results to that subtree**. Paths are
  normalized first (`~` expanded, relative paths joined to the current
  directory, `.`/`..` resolved, trailing `/` dropped) and also matched through
  symlinks (e.g. a `~/Downloads` that points into another tree), so
  `mff -p ~/Downloads/` and `mff -p .` behave like their absolute form.

The index stores each file's path, whether it looks **binary** (a `.md` that is
really a binary blob is flagged, so it is never treated as text), and **binary
metadata** (audio/video tags, image EXIF). With `--binary` the daemon
narrows by path *or* that metadata; text contents (`--content`) are always read
live and never stored.

## Performance notes

Builds stay fast on slow disks: directories are read with `readdir` (no
per-entry stat), AppleDouble `._*` files and cache directories
(`~/Library/Caches`, `Containers`, `Application Support`, `node_modules`, `.git`,
…) are skipped, and media parsing is size-gated (EXIF from a 64 KB header,
AVFoundation only for small files, embedded cover art is never read).

`index rebuild` and the daemon's initial build print a live progress line to
stderr when it is a terminal:

```
mff: indexing… 124830 entries  /Users/me/Projects/foo/node_modules
```
