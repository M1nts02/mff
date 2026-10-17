import Foundation
import CoreGraphics

// MARK: - Runtime configuration

struct Config {
    var mode: Mode = .stdin
    var searchPaths: [String] = []
    var typeFilter = TypeFilter()
    var namePattern: String?
    /// The query typed so far; kept in sync with the search field so actions
    /// that only know the config (e.g. printing the query on a mismatch) see
    /// the live text.
    var initialQuery = ""
    var outputNUL = false
    var outputIndex = false
    var autoSelectSingle = false
    var returnQueryOnMismatch = false
    var multi = false
    var numRows = 10
    var windowWidth: CGFloat = 720
    var showIcons = true
    var includeHidden = false
    var noPreview = false
    var autoplay = false
    /// Content mode only: skip regular files larger than this many bytes
    /// (default 20 MiB). Zero means no limit.
    var maxFileSize = 20 * 1024 * 1024
    var enterAction: EnterAction = .printPath
    var enterActionExplicit = false

    /// Content modifiers — they do NOT select a mode on their own; they layer
    /// onto a file search (`.files`) or `--stdin-files`:
    ///   - `--content`: also match the **text** contents of regular files (read
    ///     live; never indexed)
    ///   - `--binary` (alias `--bcontent`): also match **binary-file metadata**
    ///     (audio/video tags, image EXIF, PDF info); servable from the index
    /// Both may be given together (path OR text OR binary).
    var searchTextContent = false
    var searchBinary = false

    /// `[ui] keybinding` from config.toml (e.g. "cmd+space" / "ctrl+space").
    /// Nil disables the global hotkey.
    var keybinding: String?

    /// Patterns of paths that are never searched, from the top-level `exclude`
    /// in config.toml plus any `--exclude` flags. Applies to every mode and to
    /// both indexed and live search.
    var excludePatterns: [String] = []

    /// Index use (v3). A plain run uses the index daemon when one is running and
    /// enabled; `--no-index` forces a live filesystem walk. `indexDaemon`
    /// starts the resident index process instead of the GUI.
    var noIndex = false
    var indexDaemon = false
    var indexRebuild = false

    /// The parsed config file (icons, `[index]` settings).
    var file = ConfigFile()

    enum Mode {
        case stdin
        /// stdin, but every line is a filesystem path shown as a file item
        /// (icons, Quick Look preview, drag-out, Open / Reveal).
        case stdinFiles
        case files
        case apps
    }

    /// How lines read from stdin are interpreted.
    enum StdinKind {
        case lines
        case files
    }

    /// What the Enter key does in file / app search.
    enum EnterAction: Equatable {
        case printPath
        case open
        case reveal
    }
}
