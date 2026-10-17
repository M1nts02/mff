import Foundation

// MARK: - Terminal progress line

/// Draws a single, in-place progress line on stderr while a long build runs.
///
/// The line is truncated to the terminal width so it never wraps — a wrapped
/// line makes `\r` return to the start of the *wrapped* row, leaving a trail of
/// half-lines. When stderr is not a terminal nothing is drawn (logs stay clean).
enum ProgressLine {
    private static var lastWidth = 0
    private static var enabled: Bool { isatty(STDERR_FILENO) != 0 }

    /// Returns an `onProgress` callback that draws `<label>… N entries  <dir>`.
    static func prefix(_ label: String) -> ((Int, String) -> Void)? {
        guard enabled else { return nil }
        return { count, current in
            let width = terminalWidth()
            let head = "\(kAppName): \(label)… \(count) entries  "
            // Leave room for the head + a little padding; truncate the path so
            // the whole line fits on one row.
            let room = max(10, width - head.count - 1)
            let tail = current.count > room ? "…" + String(current.suffix(room - 1)) : current
            draw("\r\u{1B}[K" + head + tail)
        }
    }

    /// Clears the progress line (call before printing a final message).
    static func clear() {
        guard enabled, lastWidth > 0 else { return }
        fputs("\r\u{1B}[K", stderr)
        lastWidth = 0
    }

    private static func draw(_ text: String) {
        fputs(text, stderr)
        lastWidth = max(lastWidth, 1)
    }

    private static func terminalWidth() -> Int {
        var w = winsize()
        if ioctl(STDERR_FILENO, TIOCGWINSZ, &w) == 0, w.ws_col > 0 {
            return Int(w.ws_col)
        }
        let cols = ProcessInfo.processInfo.environment["COLUMNS"].flatMap(Int.init)
        return cols ?? 80
    }
}
