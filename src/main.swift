import Cocoa
import Darwin

let kAppName = "mff"
// kAppVersion is generated into src/Version.swift by package.sh.

// MARK: - Help / version

func printHelp() {
    print("""
    \(kAppName) \(kAppVersion) – GUI fuzzy finder (Spotlight-style) for files, file contents, apps and stdin

    USAGE:
      \(kAppName) [OPTIONS] [PATH|TYPE ...]

    MODES:
      stdin    --stdin [files]: read items from stdin (paths in `files` mode).
      files    Default. A PATH / TYPE / --name selects a file search; with no
               arguments the current directory is searched (stdin is a pipe:
               stdin mode). --content / --binary are modifiers, not modes.
      apps     --app: search applications by name.
    
      Commands:  config path | edit | validate | show ;
                 index rebuild [--volume PATH] | clean | stop | status
      Index:     --index-daemon (start)  ·  --no-index (bypass)

    ARGUMENTS:
      PATH                 Existing directory to search (repeatable).
                           Default: current directory (file mode).
      TYPE                 File type filter. An extension such as ".mp3", "mp3"
                           or "tar.gz", or a category such as image, video,
                           audio, document, text, archive, folder. The text
                           category also covers source code, lyrics (.lrc and
                           friends) and subtitles (.srt/.ass/.vtt/...).
                           Comma lists are allowed: image,video
      QUERY                Anything else is used as the initial search query.
                           TYPE as a bare positional must be explicit (.mp3,
                           *.mp3, tar.gz, kind:video, image[,video]); a bare
                           word that is not a category is a query.

    OPTIONS:
      --stdin [MODE]   Read items from stdin even when a path/type is given.
                       MODE: lines (default; raw strings) | files (each line is
                       a path, browsed like a file result).
      --stdin-files    Shorthand for `--stdin files`.
      --app            Search applications by name.
      --content        Also match the text contents of regular files (read
                       live, never indexed). Requires a file search or
                       --stdin files.
      --binary, --bcontent
                       Also match binary-file metadata: audio title/artist/
                       album, image EXIF, video tags (incl. MKV/WebM). Served
                       by the index when a daemon is running, else read live.
                       May be combined with --content.
      --max-filesize SIZE
                       With --content: skip files larger than SIZE (K/M/G,
                       1024-based, or bytes; 0 = no limit; default 20M).
      --enter ACTION   Enter action: path (default) | open | reveal.
      --open           Shorthand for --enter open.
      --config PATH    Use PATH instead of ~/.config/mff/config.toml
                       ($MFF_CONFIG also overrides it).
      --no-config      Ignore config.toml (pure CLI behaviour).
      --no-index       Never use the index daemon; always walk live.
      --exclude GLOB   Exclude matching paths from results (repeatable; any
                       mode).
      --index-daemon   Run the resident index process instead of the GUI
                       (alias: --indexd).
      --rebuild-index  Rebuild the index (with --index-daemon: before serving;
                       alone: rebuild now and exit). Alias: --reindex.
      --multi          Allow multi-select (not with --app).
      --autoplay       Auto-play audio/video previews (default: off).
      --hidden         Include hidden files (default: skip).
      --no-icons       Disable file icons.
      --no-preview     Disable the preview pane.
      --self-test      Run the matcher self-test and exit (0 = passed).
      -p, --path DIR       Search directory (same as PATH; repeatable).
      --onlyin DIR         Alias for --path (mdfind compatible).
      -t, --type TYPE      File type filter (repeatable). See TYPE above.
      --name TEXT          Only include files whose name contains TEXT.
      -q, --query TEXT     Initial search query.
      -n ROWS              Visible rows (default: 10).
      -w WIDTH             List width in points (default: 720).
      -0                   Print the selection followed by a NUL byte.
      -1                   Auto-select when exactly one match remains.
      -i                   Print the index of the selection instead of it.
      -m                   Print the query if nothing is selected.
      -h, --help           Show this help and exit.
      -v, --version        Show version and exit.

    EXAMPLES:
      ls | \(kAppName)
      \(kAppName) ~/Music .mp3
      \(kAppName) -p ~/Downloads -t video,image
      \(kAppName) --onlyin ~/Documents --name report
      \(kAppName) -t image -q cat
      \(kAppName) --app                 # Launchpad-like app launcher
      \(kAppName) --app | head          # just list app paths
      zoxide query -l | \(kAppName) --stdin files   # browse dirs/files from stdin
      mdfind -0 kMDItemFSName=foo | \(kAppName) --stdin files
      \(kAppName) ~/Downloads --enter reveal   # Enter reveals in Finder
      \(kAppName) --content ~/notes TODO       # files containing "TODO"
      \(kAppName) --binary ~/Music neon        # audio by metadata
      \(kAppName) --content --binary ~/x term  # text OR binary metadata
      \(kAppName) --content --stdin files      # piped paths, search contents
      \(kAppName) config path|edit|validate|show  # manage ~/.config/mff/config.toml
      \(kAppName) index status                 # daemon + per-volume state (shows a pending version rebuild)
      \(kAppName) index rebuild --volume /Volumes/X   # rebuild one volume
      \(kAppName) index clean|stop             # delete the index / stop the daemon
    """)
}

func printVersion() {
    print("\(kAppName) \(kAppVersion)")
}

// MARK: - Argument parsing

/// Whether a positional is meant as a TYPE filter (as opposed to a query).
/// Extensions must be explicit (`.mp3`, `*.mp3`, `tar.gz`) or `kind:`-prefixed;
/// bare words count only as a category alias (`image`, `image,video`).
func isExplicitTypeToken(_ raw: String) -> Bool {
    var t = raw.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("kind:") { return true }
    if t.hasPrefix(".") || t.hasPrefix("*.") || t.contains(".") { return true }
    let parts = t.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    return !parts.isEmpty && parts.allSatisfy { FileCategory.aliases($0) != nil }
}

func parseTypeToken(_ raw: String) -> TypeFilter? {
    var t = raw.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("kind:") {
        t = String(t.dropFirst(5))
    }
    guard !t.isEmpty else { return nil }

    var filter = TypeFilter()
    for partRaw in t.split(separator: ",") {
        var p = String(partRaw).trimmingCharacters(in: .whitespaces)
        if p.isEmpty { continue }

        var isExt = false
        if p.hasPrefix("*.") {
            p = String(p.dropFirst(2))
            isExt = true
        } else if p.hasPrefix(".") {
            p = String(p.dropFirst())
            isExt = true
        }
        if p.contains(".") { isExt = true }

        if isExt {
            filter.extensions.insert(p.lowercased())
        } else if let cat = FileCategory.aliases(p) {
            filter.categories.insert(cat)
        } else {
            // Unknown bare token: treat as extension.
            filter.extensions.insert(p.lowercased())
        }
    }
    return filter.isEmpty ? nil : filter
}

/// Parses a human-readable size ("20", "512K", "1.5M", "2G"; 1024-based)
/// into bytes. Returns nil for malformed input.
func parseByteSize(_ raw: String) -> Int? {
    let s = raw.trimmingCharacters(in: .whitespaces).uppercased()
    guard !s.isEmpty else { return nil }
    var number = s
    var multiplier = 1
    let suffixes: [(String, Int)] = [
        ("KB", 1024), ("K", 1024),
        ("MB", 1024 * 1024), ("M", 1024 * 1024),
        ("GB", 1024 * 1024 * 1024), ("G", 1024 * 1024 * 1024),
        ("B", 1)
    ]
    for (suffix, mult) in suffixes where number.hasSuffix(suffix) {
        number = String(number.dropLast(suffix.count))
        multiplier = mult
        break
    }
    guard let value = Double(number), value >= 0 else { return nil }
    let bytes = value * Double(multiplier)
    guard bytes < Double(Int.max) else { return nil }
    return Int(bytes)
}

func parseEnterAction(_ raw: String) -> Config.EnterAction? {
    switch raw.lowercased() {
    case "path", "print", "stdout", "echo":
        return .printPath
    case "open", "launch":
        return .open
    case "reveal", "finder", "show":
        return .reveal
    default:
        return nil
    }
}

/// Parses the optional argument to `--stdin` describing how lines are read.
func parseStdinKind(_ raw: String) -> Config.StdinKind? {
    switch raw.lowercased() {
    case "lines", "line", "text", "raw", "strings":
        return .lines
    case "files", "file", "paths", "path", "dirs", "dir", "directories", "apps", "app":
        return .files
    default:
        return nil
    }
}

func parseArguments(_ args: [String], configFile cfgFile: ConfigFile) -> Config {
    var cfg = Config()
    cfg.file = cfgFile
    // Seed the search-time exclude patterns from config.toml; `--exclude` adds
    // to them below.
    cfg.excludePatterns = cfgFile.exclude
    var positionals: [String] = []
    var forceStdin = false
    var stdinKind: Config.StdinKind = .lines
    var searchApps = false
    var searchContent = false
    var cliIconsSet = false
    var cliPreviewSet = false
    var cliRowsSet = false
    var cliWidthSet = false

    var i = 1
    while i < args.count {
        let a = args[i]
        switch a {
        case "-h", "--help":
            printHelp()
            exit(0)
        case "-v", "--version":
            printVersion()
            exit(0)
        case "-0", "--print0":
            cfg.outputNUL = true
        case "-1":
            cfg.autoSelectSingle = true
        case "-i", "--index":
            cfg.outputIndex = true
        case "-m":
            cfg.returnQueryOnMismatch = true
        case "--hidden":
            cfg.includeHidden = true
        case "--no-icons":
            cfg.showIcons = false
            cliIconsSet = true
        case "--icons":
            cfg.showIcons = true
            cliIconsSet = true
        case "--no-preview":
            cfg.noPreview = true
            cliPreviewSet = true
        case "--preview":
            cfg.noPreview = false
            cliPreviewSet = true
        case "--stdin":
            forceStdin = true
            // Optional mode argument: `--stdin files`, `--stdin apps`.
            if i + 1 < args.count, let kind = parseStdinKind(args[i + 1]) {
                stdinKind = kind
                i += 1
            }
        case "--stdin-files":
            forceStdin = true
            stdinKind = .files
        case "--autoplay":
            cfg.autoplay = true
        case "--app":
            searchApps = true
        case "--content":
            searchContent = true
            cfg.searchTextContent = true
        case "--binary", "--bcontent":
            searchContent = true
            cfg.searchBinary = true
        case "--max-filesize", "--max-size":
            i += 1
            if i < args.count {
                guard let size = parseByteSize(args[i]) else {
                    fputs("\(kAppName): invalid --max-filesize value: \(args[i]) (use e.g. 20M, 512K, 1G)\n", stderr)
                    exit(1)
                }
                cfg.maxFileSize = size
            }
        case "--enter":
            i += 1
            if i < args.count {
                guard let action = parseEnterAction(args[i]) else {
                    fputs("\(kAppName): invalid --enter value: \(args[i]) (use path, open or reveal)\n", stderr)
                    exit(1)
                }
                cfg.enterAction = action
                cfg.enterActionExplicit = true
            }
        case "--open":
            cfg.enterAction = .open
            cfg.enterActionExplicit = true
        case "--exclude", "--exclude-path":
            i += 1
            if i < args.count { cfg.excludePatterns.append(args[i]) }
        case "--no-index":
            cfg.noIndex = true
        case "--index-daemon", "--indexd":
            cfg.indexDaemon = true
        case "--rebuild-index", "--reindex":
            cfg.indexRebuild = true
        case "--multi":
            cfg.multi = true
        case "-n":
            i += 1
            if i < args.count { cfg.numRows = Int(args[i]) ?? cfg.numRows; cliRowsSet = true }
        case "-w":
            i += 1
            if i < args.count { cfg.windowWidth = CGFloat(Double(args[i]) ?? Double(cfg.windowWidth)); cliWidthSet = true }
        case "-p", "--path", "--onlyin":
            i += 1
            if i < args.count { cfg.searchPaths.append(args[i]) }
        case "-t", "--type":
            i += 1
            if i < args.count, let f = parseTypeToken(args[i]) {
                cfg.typeFilter.extensions.formUnion(f.extensions)
                cfg.typeFilter.categories.formUnion(f.categories)
            }
        case "-q", "--query":
            i += 1
            if i < args.count {
                cfg.initialQuery += (cfg.initialQuery.isEmpty ? "" : " ") + args[i]
            }
        case "--name", "-name":
            i += 1
            if i < args.count { cfg.namePattern = args[i] }
        default:
            if a.hasPrefix("--stdin=") {
                forceStdin = true
                let value = String(a.dropFirst("--stdin=".count))
                guard let kind = parseStdinKind(value) else {
                    fputs("\(kAppName): invalid --stdin value: \(value) (use lines or files)\n", stderr)
                    exit(1)
                }
                stdinKind = kind
            } else if a.hasPrefix("-"), a.count > 1 {
                fputs("\(kAppName): unknown option: \(a)\n", stderr)
                printHelp()
                exit(1)
            } else {
                positionals.append(a)
            }
        }
        i += 1
    }

    // Interpret positional arguments: directory -> path, explicit type token
    // (".mp3", "image", "tar.gz", "kind:video", "image,video") -> filter,
    // anything else -> initial query. A bare word that is not a known category
    // is a query, not an extension: otherwise `mff agent` would filter by the
    // extension "agent" and show nothing.
    for p in positionals {
        if isDirectory(p) {
            cfg.searchPaths.append(p)
        } else if isExplicitTypeToken(p), let f = parseTypeToken(p) {
            cfg.typeFilter.extensions.formUnion(f.extensions)
            cfg.typeFilter.categories.formUnion(f.categories)
        } else {
            cfg.initialQuery += (cfg.initialQuery.isEmpty ? "" : " ") + p
        }
    }

    // Decide mode: --stdin forces
    // stdin (optionally as files); --app always selects app search; otherwise
    // any file directive selects a filesystem search.
    //
    // --content / --binary are MODIFIERS, not modes: they must accompany a file
    // search (path/type/--name) or `--stdin files`, and never select a mode by
    // themselves.
    let hasFileDirective = !cfg.searchPaths.isEmpty || !cfg.typeFilter.isEmpty
        || cfg.namePattern != nil
    let contentModifiers = searchContent
    let searchingFiles = !forceStdin && !searchApps && hasFileDirective
    let stdinAsFiles = forceStdin && stdinKind == .files
    if forceStdin {
        switch stdinKind {
        case .lines: cfg.mode = .stdin
        case .files: cfg.mode = .stdinFiles
        }
    } else if searchApps {
        cfg.mode = .apps
    } else if hasFileDirective {
        cfg.mode = .files
        if cfg.searchPaths.isEmpty {
            cfg.searchPaths = [FileManager.default.currentDirectoryPath]
        }
    } else if isatty(STDIN_FILENO) == 0 {
        // No arguments but stdin is a pipe/file: read items from it, fzf-style.
        cfg.mode = .stdin
    } else {
        // No arguments on a terminal: search the current directory (like fzf).
        // With an index daemon the path is used as a prefix filter; otherwise
        // the directory is walked live. Use --stdin to force reading a pipe.
        cfg.mode = .files
        cfg.searchPaths = [FileManager.default.currentDirectoryPath]
    }

    // --content / --binary require a file search target (or --stdin files).
    if contentModifiers && !(searchingFiles || stdinAsFiles) {
        fputs("\(kAppName): --content / --binary must be used with a file search (a PATH, TYPE or --name) or --stdin-files\n", stderr)
        exit(1)
    }

    // Launchpad behaviour: open the app on Enter when interactive. Keep plain
    // path output when stdout is redirected so the tool stays pipeable. An
    // explicit --enter / --open always wins.
    if searchApps && !cfg.enterActionExplicit && isatty(STDOUT_FILENO) != 0 {
        cfg.enterAction = .open
    }

    // Apply [ui] from config.toml for anything the CLI did not set explicitly.
    if !cliIconsSet, let v = cfgFile.uiIcons { cfg.showIcons = v }
    if !cliPreviewSet, let v = cfgFile.uiPreview { cfg.noPreview = !v }
    if !cliRowsSet, let v = cfgFile.uiRows, v > 0 { cfg.numRows = v }
    if !cliWidthSet, let v = cfgFile.uiWidth, v >= 400 { cfg.windowWidth = CGFloat(v) }
    if let kb = cfgFile.uiKeybinding, !kb.isEmpty { cfg.keybinding = kb }

    // Multi-select is a file/stdin concept; app search is a single-action
    // launcher, so --multi does not apply there.
    if cfg.multi && searchApps {
        fputs("\(kAppName): --multi is not supported with --app; ignoring --multi\n", stderr)
        cfg.multi = false
    }

    return cfg
}

// MARK: - Config subcommands

/// Handles `mff config path|edit|validate`. Returns true if a subcommand ran
/// (so the caller should not start the GUI).
func handleConfigCommand(_ args: [String]) -> Bool {
    guard args.count >= 2, args[1] == "config" else { return false }

    // Allow an optional --config PATH after the subcommand.
    var pathOverride: String?
    var sub: String?
    var i = 2
    while i < args.count {
        let a = args[i]
        if a == "--config" {
            i += 1
            if i < args.count { pathOverride = args[i] }
        } else {
            sub = a
        }
        i += 1
    }
    let path = ConfigFileLoader.defaultPath(override: pathOverride)
    let subcommand = sub ?? "path"

    switch subcommand {
    case "path":
        print(path)
        exit(0)
    case "edit":
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            try? defaultConfigTemplate.write(toFile: path, atomically: true, encoding: .utf8)
        }
        let editor = ProcessInfo.processInfo.environment["EDITOR"] ?? "vi"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [editor, path]
        try? p.run()
        p.waitUntilExit()
        exit(0)
    case "validate":
        if !FileManager.default.fileExists(atPath: path) {
            fputs("\(kAppName): config not found: \(path)\n", stderr)
            exit(1)
        }
        let parsed = ConfigFileLoader.load(path: path)
        var ok = true
        // Parser warnings (unknown keys/tables, bad values) are already printed
        // to stderr by the loader; fold them into the pass/fail result here.
        if !parsed.warnings.isEmpty { ok = false }
        if ok {
            print("\(kAppName): \(path) OK")
            exit(0)
        }
        exit(1)
    case "show":
        let parsed = ConfigFileLoader.load(path: path)
        print(renderConfig(parsed, path: path))
        exit(0)
    default:
        fputs("\(kAppName): unknown config subcommand '\(subcommand)' (use path, edit, validate or show)\n", stderr)
        exit(1)
    }
}

/// Human-readable dump of the effective parsed config (`mff config show`).
func renderConfig(_ cfg: ConfigFile, path: String) -> String {
    var out = "config: \(path)\n"
    out += "exclude: \(cfg.exclude.isEmpty ? "[]" : cfg.exclude.joined(separator: ", "))\n"

    out += "\n[ui]\n"
    func uiLine(_ k: String, _ v: Any?) {
        out += "  \(k) = \(v.map { String(describing: $0) } ?? "(unset)")\n"
    }
    uiLine("icons", cfg.uiIcons)
    uiLine("preview", cfg.uiPreview)
    uiLine("keybinding", cfg.uiKeybinding)
    uiLine("rows", cfg.uiRows)
    uiLine("width", cfg.uiWidth)

    if !cfg.icons.isEmpty {
        out += "\n[icons.overrides] (\(cfg.icons.count))\n"
        for key in cfg.icons.keys.sorted() { out += "  \(key) = \(cfg.icons[key]!)\n" }
    }
    out += "\n[index]\n  volumes = \(cfg.indexVolumes)\n  exclude = \(cfg.indexExclude)\n"

    if !cfg.warnings.isEmpty {
        out += "\nwarnings (\(cfg.warnings.count)):\n"
        for w in cfg.warnings { out += "  \(w)\n" }
    }
    return out
}

let defaultConfigTemplate = """
# mff configuration — see https://github.com/m1nts02/mff

# Paths never searched in ANY mode (indexed or live). Glob-ish patterns; add
# more with `--exclude` on the command line.
# exclude = ["**/node_modules", "**/.git", "*.tmp"]

# Everything is configured here (no settings panel). CLI flags still win.
[ui]
# icons = true
# preview = true
# rows = 10
# width = 720
# keybinding = "cmd+space"   # global hotkey; keeps mff resident in the menu bar

# Override icons per extension.
# [icons.overrides]
# rs = "dev.rust"

# Optional filename index (start with `mff --index-daemon`).
# `exclude` keeps paths out of the index (glob: **/name, **/name/**, *.ext;
# a leading ~ or ${HOME} expands to your home directory).
# [index]
# enabled = true                                  # may a plain mff use the daemon?
# volumes = "auto"                                # built-in volumes (auto/none/list)
# external_volumes = "none"                       # external: none (default) | all | list (exFAT ok)
# exclude = [
#     "**/node_modules", "**/target", "**/build", "**/dist", "**/out",
#     "**/DerivedData", "**/.build", "**/.gradle", "**/__pycache__",
#     "**/.venv", "**/Pods", "**/.git", "**/.hg", "**/.svn",
#     "**/.idea", "**/.vscode", "**/.Spotlight-V100", "**/.fseventsd",
#     "~/Library/Caches", "~/Library/Containers",
#     "~/Library/Application Support", "~/.cache",
#     "*.tmp", "*.log", "*.swp",
# ]
"""

// MARK: - Index subcommands

/// Handles `mff index rebuild|clean|stop|status`. Returns true if a subcommand ran.
func handleIndexCommand(_ args: [String]) -> Bool {
    guard args.count >= 2, args[1] == "index" else { return false }

    var pathOverride: String?
    var sub: String?
    var only: String?
    var i = 2
    while i < args.count {
        let a = args[i]
        if a == "--config" {
            i += 1
            if i < args.count { pathOverride = args[i] }
        } else if a.hasPrefix("--config=") {
            pathOverride = String(a.dropFirst("--config=".count))
        } else if a == "--volume" || a == "-v" {
            i += 1
            if i < args.count { only = args[i] }
        } else {
            sub = a
        }
        i += 1
    }
    let subcommand = sub ?? "status"
    let cfgPath = ConfigFileLoader.defaultPath(override: pathOverride)
    let config = ConfigFileLoader.load(path: cfgPath)

    switch subcommand {
    case "rebuild":
        let count = IndexManager.rebuild(config: config, only: only)
        exit(count < 0 ? 1 : 0)
    case "clean", "clear":
        let removed = IndexManager.clean()
        print("\(kAppName): removed \(removed) index file(s)")
        exit(0)
    case "stop":
        if IndexManager.stop() {
            print("\(kAppName): stopped the index daemon")
            exit(0)
        } else {
            fputs("\(kAppName): no running index daemon\n", stderr)
            exit(1)
        }
    case "status":
        IndexManager.status()
        exit(0)
    default:
        fputs("\(kAppName): unknown index subcommand '\(subcommand)' (use rebuild, clean, stop or status)\n", stderr)
        exit(1)
    }
}

// MARK: - Matching self-test

/// `mff --self-test`: runs the matcher and index-hit item construction without
/// a GUI and prints one line per case. Used to verify search results in a
/// headless/CI environment (a GUI run needs a session and a focusable window).
func runSelfTest(_ args: [String]) -> Int32 {
    struct Case { let query: String; let path: String; let isDirectory: Bool; let expect: Bool }
    let cases: [Case] = [
        Case(query: "agent", path: "/p/src/Agent.swift", isDirectory: false, expect: true),
        Case(query: "agnt", path: "/p/src/Agent.swift", isDirectory: false, expect: true),
        Case(query: "agent", path: "/p/src/Index/FileIndex.swift", isDirectory: false, expect: false),
        Case(query: "xmake", path: "/p/xmake.lua", isDirectory: false, expect: true),
        Case(query: "proj", path: "/p/project", isDirectory: true, expect: true),
        Case(query: "proj\u{2003}xmake", path: "/p/project/xmake.lua", isDirectory: false, expect: true),
        Case(query: "Swift", path: "/p/src/INDEX/SWIFT", isDirectory: false, expect: true),
    ]
    var failures = 0
    for c in cases {
        let item = SearchableItem(indexPath: c.path, isDirectory: c.isDirectory,
                                  binaryText: nil, indexBinary: false)
        let got = FuzzyMatcher.match(query: c.query, in: item) != nil
        let ok = got == c.expect
        if !ok { failures += 1 }
        print("\(ok ? "ok  " : "FAIL") \(c.query)  \(c.path)  -> \(got) (expected \(c.expect))")
    }
    print(failures == 0 ? "self-test: all \(cases.count) passed" : "self-test: \(failures) failed")
    return failures == 0 ? 0 : 1
}

// MARK: - Entry point

if CommandLine.arguments.dropFirst().contains("--self-test") { exit(runSelfTest(CommandLine.arguments)) }
if handleConfigCommand(CommandLine.arguments) { exit(0) }
if handleIndexCommand(CommandLine.arguments) { exit(0) }

// Parse --config / --no-config out of the argument list; everything else is
// passed through to parseArguments unchanged.
var configPathOverride: String?
var noConfig = false
var passthrough: [String] = [CommandLine.arguments.first ?? kAppName]
var ai = 1
while ai < CommandLine.arguments.count {
    let a = CommandLine.arguments[ai]
    if a == "--config" {
        ai += 1
        if ai < CommandLine.arguments.count { configPathOverride = CommandLine.arguments[ai] }
    } else if a.hasPrefix("--config=") {
        configPathOverride = String(a.dropFirst("--config=".count))
    } else if a == "--no-config" {
        noConfig = true
    } else {
        passthrough.append(a)
    }
    ai += 1
}

let resolvedConfigPath = ConfigFileLoader.defaultPath(override: configPathOverride)
let loadedConfig = noConfig ? ConfigFile() : ConfigFileLoader.load(path: resolvedConfigPath)

let config = parseArguments(passthrough, configFile: loadedConfig)

// Index daemon mode: become the resident index process instead of the GUI.
if config.indexDaemon {
    let daemon = IndexDaemon(config: loadedConfig)
    // Refuse to start a second daemon before doing any (expensive) index work.
    guard daemon.claimSingleInstance() else {
        if let probe = IndexClient().probe() {
            fputs("\(kAppName): index-daemon already running (pid \(probe.pid)); exiting\n", stderr)
        } else {
            fputs("\(kAppName): index-daemon: another instance holds the lock; exiting\n", stderr)
        }
        exit(0)
    }
    daemon.prepareIndex(forceRebuild: config.indexRebuild)
    daemon.run()
    exit(0)
}

// `--rebuild-index` on its own (without --index-daemon) rebuilds now and exits.
if config.indexRebuild {
    let count = IndexManager.rebuild(config: loadedConfig)
    exit(count < 0 ? 1 : 0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate(config: config)
app.delegate = delegate
app.run()
