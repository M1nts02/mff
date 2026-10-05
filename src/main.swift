import Cocoa
import Darwin

let kAppName = "mff"
// kAppVersion is generated into src/Version.swift by package.sh.

// MARK: - Help / version

func printHelp() {
    print("""
    \(kAppName) \(kAppVersion) – GUI fuzzy finder (Spotlight-style) for files and stdin

    USAGE:
      \(kAppName) [OPTIONS] [PATH|TYPE ...]

    With no path/type arguments, \(kAppName) reads lines from stdin and behaves
    like fzf. When a path or a type filter is given, it searches the filesystem
    (like mdfind) and lets you fuzzy-search the results.

    ARGUMENTS:
      PATH                 Existing directory to search (repeatable).
                           Default: current directory (file mode).
      TYPE                 File type filter. An extension such as ".mp3", "mp3"
                           or "tar.gz", or a category such as image, video,
                           audio, document, text, archive, folder.
                           Comma lists are allowed: image,video
      QUERY                Anything else is used as the initial search query.

    OPTIONS:
          --app            Search applications only (like Launchpad). Matches the
                           app name only (not the full path) and defaults to the
                           standard application directories; opens the selected
                           app on Enter when interactive, else prints paths.
          --autoplay       Auto-play audio/video in the preview pane when
                           selected (default: off; press Cmd+Enter to toggle).
          --enter ACTION   Enter-key behaviour in file/app search:
                             path    print the selected path (default)
                             open    open with the default application
                             reveal  reveal the selected file in Finder
                           Items without a path (stdin) always print.
          --open           Shorthand for --enter open.
      -p, --path DIR       Search directory (same as PATH argument, repeatable).
          --onlyin DIR     Alias for --path (mdfind compatible).
      -t, --type TYPE      File type filter (repeatable). See TYPE above.
          --name TEXT      Only include files whose name contains TEXT.
      -q, --query TEXT     Initial search query.
      -n ROWS              Number of visible rows (default: 10).
      -w WIDTH             List area width in points (default: 720); the preview
                           pane is added on the right in file mode.
      -0                   Print selection followed by a NUL byte.
      -1                   Auto-select if exactly one match remains.
      -i                   Print the index of the selected item instead of it.
      -m                   Return the query string if nothing is selected.
          --hidden         Include hidden files (default: skip them).
          --no-icons       Disable file icons.
          --no-preview     Disable the preview pane.
      -h, --help           Show this help and exit.
      -v, --version        Show version and exit.

    KEYBOARD:
      ↑/↓, Ctrl+P/N/J/K    Move selection
      PgUp/PgDn            Move selection by a page
      Ctrl+U/Ctrl+D        Move selection by a half page
      Home/End             First / last item (list focused)
      ⌘1..⌘9               Select the Nth row directly
      ⌘O                    Open the selected file with its default app
      ⌘R                    Reveal the selected file in Finder
      ⌘T                    Open the file-type selector (file search)
      ⌘↩                    Play / toggle auto-play of audio/video previews
      Tab                  Insert a search-term separator
      ↩                    Accept: print the current item
      esc                  Clear query, then cancel
      ctrl+c               Cancel

    BUTTONS (bottom bar):
      Open / Reveal in Finder / Return   same as ⌘O / ⌘R / ↩
      Type popup (file search)           filter results by file type

    SEARCH:
      Terms are separated by Tab (spaces are ordinary characters); every term
      must match (AND) somewhere in the full path.
      Each term is shown as its own coloured tag in the query field, and its
      matches are highlighted in the same colour in the results.
        text        fuzzy match (letters in order, anywhere in the path)
        'text       exact text
        .ext        file extension (multi-part like .tar.gz works)
        ^text       file name starts with text
        text$       file name ends with text
        !text       exclude anything matching text
      e.g.  downloads<Tab>.mp3<Tab>report

    EXAMPLES:
      ls | \(kAppName)
      \(kAppName) ~/Music .mp3
      \(kAppName) -p ~/Downloads -t video,image
      \(kAppName) --onlyin ~/Documents --name report
      \(kAppName) -t image -q cat
      \(kAppName) --app                 # Launchpad-like app launcher
      \(kAppName) --app | head          # just list app paths
      \(kAppName) ~/Downloads --enter reveal   # Enter reveals in Finder
    """)
}

func printVersion() {
    print("\(kAppName) \(kAppVersion)")
}

// MARK: - Argument parsing

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

func isDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}

/// Standard locations Launchpad-like tools search for applications.
func standardAppPaths() -> [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    // Note: Utilities subfolders are covered by the recursive scan of their
    // parents, so we deliberately do not list them separately (avoids dupes).
    let candidates = [
        "/Applications",
        "/System/Applications",
        "/System/Library/CoreServices/Applications",
        home + "/Applications"
    ]
    let existing = candidates.filter { isDirectory($0) }
    return existing.isEmpty ? ["/Applications"] : existing
}

func parseArguments(_ args: [String]) -> Config {
    var cfg = Config()
    var positionals: [String] = []

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
        case "--no-preview":
            cfg.noPreview = true
        case "--autoplay":
            cfg.autoplay = true
        case "--app":
            cfg.searchApps = true
            cfg.typeFilter.categories.insert(.app)
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
        case "-n":
            i += 1
            if i < args.count { cfg.numRows = Int(args[i]) ?? cfg.numRows }
        case "-w":
            i += 1
            if i < args.count { cfg.windowWidth = CGFloat(Double(args[i]) ?? Double(cfg.windowWidth)) }
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
            if a.hasPrefix("-"), a.count > 1 {
                fputs("\(kAppName): unknown option: \(a)\n", stderr)
                printHelp()
                exit(1)
            } else {
                positionals.append(a)
            }
        }
        i += 1
    }

    // Interpret positional arguments: directory -> path, type token -> filter,
    // anything else -> initial query.
    for p in positionals {
        if isDirectory(p) {
            cfg.searchPaths.append(p)
        } else if let f = parseTypeToken(p) {
            cfg.typeFilter.extensions.formUnion(f.extensions)
            cfg.typeFilter.categories.formUnion(f.categories)
        } else {
            cfg.initialQuery += (cfg.initialQuery.isEmpty ? "" : " ") + p
        }
    }

    // Decide mode: any file directive switches us into filesystem mode.
    let hasFileDirective = !cfg.searchPaths.isEmpty || !cfg.typeFilter.isEmpty
        || cfg.namePattern != nil || cfg.searchApps
    if hasFileDirective {
        cfg.mode = .files
        if cfg.searchPaths.isEmpty {
            cfg.searchPaths = cfg.searchApps
                ? standardAppPaths()
                : [FileManager.default.currentDirectoryPath]
        }
    } else {
        cfg.mode = .stdin
    }

    // Launchpad behaviour: open the app on Enter when interactive. Keep plain
    // path output when stdout is redirected so the tool stays pipeable. An
    // explicit --enter / --open always wins.
    if cfg.searchApps && !cfg.enterActionExplicit && isatty(STDOUT_FILENO) != 0 {
        cfg.enterAction = .open
    }

    return cfg
}

// MARK: - Entry point

let config = parseArguments(CommandLine.arguments)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate(config: config)
app.delegate = delegate
app.run()
