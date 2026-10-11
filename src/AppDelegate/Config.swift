import Foundation
import CoreGraphics

// MARK: - Runtime configuration

struct Config {
    var mode: Mode = .stdin
    var searchPaths: [String] = []
    var typeFilter = TypeFilter()
    var namePattern: String?
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

    enum Mode {
        case stdin
        /// stdin, but every line is a filesystem path shown as a file item
        /// (icons, Quick Look preview, drag-out, Open / Reveal).
        case stdinFiles
        case files
        case content
        case apps
    }

    /// How lines read from stdin are interpreted.
    enum StdinKind {
        case lines
        case files
    }

    /// What the Enter key does in file / app search.
    enum EnterAction {
        case printPath
        case open
        case reveal
    }
}
