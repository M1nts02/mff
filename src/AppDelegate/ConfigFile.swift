import Foundation

// MARK: - Config file (config.toml)

/// A parsed `config.toml`. Every field is optional / defaulted so a partial or
/// missing file behaves exactly like no file at all.
struct ConfigFile {
    /// Top-level `exclude` patterns: paths that are never *searched* (in either
    /// indexed or live mode), independent of `[index] exclude` (which only
    /// keeps paths out of the index).
    var exclude: [String] = []
    /// Icon overrides keyed by extension.
    var icons: [String: String] = [:]
    /// `[index]` — controls the optional filename index / daemon.
    /// `indexEnabled` gates whether a plain `mff` may use the daemon at all.
    var indexEnabled: Bool = true
    var indexVolumes: String = "auto"
    /// External volumes to index: "none" (default), "all", or a path list.
    var indexExternalVolumes: String = "none"
    var indexExclude: [String] = []
    /// `[ui]` — icons / preview / keybinding / rows / width. `nil` means "unset"
    /// so the CLI/default stays in effect.
    var uiIcons: Bool?
    var uiPreview: Bool?
    var uiKeybinding: String?
    var uiRows: Int?
    var uiWidth: Double?
    /// Non-fatal problems found while parsing (unknown keys/tables, bad values).
    /// Empty for a clean file; each is printed to stderr when the file loads.
    var warnings: [String] = []
}

// MARK: - Locating the file

enum ConfigFileLoader {
    /// Config path resolution: `$MFF_CONFIG` → `~/.config/mff/config.toml`.
    /// `override` (from `--config`) wins over the environment.
    static func defaultPath(override: String? = nil) -> String {
        if let override, !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        if let env = ProcessInfo.processInfo.environment["MFF_CONFIG"], !env.isEmpty {
            return (env as NSString).expandingTildeInPath
        }
        return homeConfigPath()
    }

    static func homeConfigPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.config/mff/config.toml"
    }

    /// Parses the config file. A missing file yields the empty (all-default)
    /// config. A malformed file prints a clear error to stderr and still yields
    /// the defaults already parsed, so the app never fails to start.
    static func load(path: String) -> ConfigFile {
        guard FileManager.default.fileExists(atPath: path) else {
            return ConfigFile()
        }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            fputs("\(kAppName): cannot read config: \(path)\n", stderr)
            return ConfigFile()
        }
        var parser = TOMLParser(text: text, path: path)
        // `warn` prints each problem as it is found (once per load).
        return parser.parse()
    }
}

// MARK: - Minimal TOML subset parser

/// Parses the small TOML subset mff's config uses: `[table]` / `[table.sub]`
/// headers, and `key = value` where value is a string, bool, integer, or an
/// array of strings. Anything else is reported with a line number and skipped.
private struct TOMLParser {
    let lines: [String]
    let path: String
    var cfg = ConfigFile()

    init(text: String, path: String) {
        self.lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        self.path = path
    }

    mutating func parse() -> ConfigFile {
        var table: [String] = []
        // A multi-line array value is accumulated here: the key plus the joined
        // bracket contents until a line closes the array.
        var pendingKey: (key: String, text: String, lineNo: Int)?
        for (index, rawLine) in lines.enumerated() {
            let lineNo = index + 1
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)

            // Continuation of a multi-line array.
            if var pending = pendingKey {
                pending.text += " " + line
                if bracketBalance(pending.text) > 0,
                   line.firstIndex(of: "=") == nil {
                    pendingKey = pending
                    continue
                }
                pendingKey = nil
                let valueText = pending.text
                if let value = parseValue(valueText) {
                    apply(key: pending.key, value: value, table: table, lineNo: pending.lineNo)
                } else {
                    warn("invalid value for '\(pending.key)'", pending.lineNo)
                }
                // The closing line of the array is consumed; do not reprocess
                // it as a key (unless it also starts a new `key = ...`).
                if line.isEmpty || line.firstIndex(of: "=") == nil { continue }
            }

            if line.isEmpty { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                let inner = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                let parts = inner.split(separator: ".").map { String($0).trimmingCharacters(in: .whitespaces) }
                if parts.isEmpty || parts.contains(where: { $0.isEmpty }) {
                    warn("malformed table header", lineNo)
                    table = []
                } else {
                    table = parts
                }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else {
                warn("expected key = value", lineNo)
                continue
            }
            var key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var valueText = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                warn("expected key = value", lineNo)
                continue
            }
            // Start of a multi-line array: keep reading until balanced.
            if valueText.hasPrefix("["), bracketBalance(valueText) > 0 {
                pendingKey = (key, valueText, lineNo)
                continue
            }
            _ = key
            guard let value = parseValue(valueText) else {
                warn("invalid value for '\(key)'", lineNo)
                continue
            }
            apply(key: key, value: value, table: table, lineNo: lineNo)
        }
        return cfg
    }

    // MARK: table dispatch

    private mutating func apply(key: String, value: TOMLValue, table: [String], lineNo: Int) {
        switch table {
        case []:
            if key == "exclude", let a = value.array { cfg.exclude = a }
            else { warn("unknown top-level key '\(key)'", lineNo) }
        case ["icons"]:
            if let s = value.string { cfg.icons[key] = s }
        case ["icons", "overrides"]:
            if let s = value.string { cfg.icons[key] = s }
        case ["index"]:
            switch key {
            case "enabled": cfg.indexEnabled = value.bool ?? true
            case "volumes": if let s = value.string { cfg.indexVolumes = s }
            case "external_volumes", "external-volumes": if let s = value.string { cfg.indexExternalVolumes = s }
            case "exclude": if let a = value.array { cfg.indexExclude = a }
            default: warn("unknown key '\(key)' in [index]", lineNo)
            }
        case ["ui"]:
            switch key {
            case "icons": cfg.uiIcons = value.bool
            case "preview": cfg.uiPreview = value.bool
            case "keybinding": cfg.uiKeybinding = value.string
            case "rows": cfg.uiRows = value.int
            case "width": cfg.uiWidth = value.double
            default: warn("unknown key '\(key)' in [ui]", lineNo)
            }
        default:
            warn("unknown table [\(table.joined(separator: "."))]", lineNo)
        }
    }

    // MARK: value parsing

    private enum TOMLValue {
        case string(String)
        case bool(Bool)
        case int(Int)
        case array([String])

        var string: String? { if case let .string(s) = self { return s }; return nil }
        var int: Int? { if case let .int(n) = self { return n }; return nil }
        var double: Double? {
            switch self {
            case .int(let n): return Double(n)
            case .string(let s): return Double(s)
            default: return nil
            }
        }
        var bool: Bool? { if case let .bool(b) = self { return b }; return nil }
        var array: [String]? { if case let .array(a) = self { return a }; return nil }
    }

    private func parseValue(_ raw: String) -> TOMLValue? {
        if raw.hasPrefix("\"") {
            return parseString(raw).map(TOMLValue.string)
        }
        if raw.hasPrefix("[") {
            guard let strings = parseStringArray(raw) else { return nil }
            return .array(strings)
        }
        switch raw {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default:
            if let n = Int(raw) { return .int(n) }
            if !raw.isEmpty && !raw.contains(" ") { return .string(raw) }
            return nil
        }
    }

    /// A double-quoted string with basic escapes. Trailing junk after the
    /// closing quote is rejected.
    private func parseString(_ raw: String) -> String? {
        guard raw.hasPrefix("\"") else { return nil }
        var result = ""
        var escaped = false
        var chars = raw.dropFirst()
        while let c = chars.first {
            chars = chars.dropFirst()
            if escaped {
                switch c {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                default: result.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                let rest = chars.trimmingCharacters(in: .whitespaces)
                return rest.isEmpty ? result : nil
            } else {
                result.append(c)
            }
        }
        return nil
    }

    private func parseStringArray(_ raw: String) -> [String]? {
        guard raw.hasPrefix("["), raw.hasSuffix("]") else { return nil }
        let inner = raw.dropFirst().dropLast()
        var items: [String] = []
        var current = ""
        var inString = false
        var escaped = false
        var sawQuote = false
        for c in inner {
            if inString {
                if escaped {
                    switch c {
                    case "n": current.append("\n")
                    case "t": current.append("\t")
                    case "\"": current.append("\"")
                    case "\\": current.append("\\")
                    default: current.append(c)
                    }
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                } else {
                    current.append(c)
                }
            } else if c == "\"" {
                inString = true
                sawQuote = true
            } else if c == "," {
                if sawQuote { items.append(current) }
                current = ""
                sawQuote = false
            } else if !c.isWhitespace {
                // A bare (unquoted) array element.
                current.append(c)
                sawQuote = true
            }
        }
        if sawQuote { items.append(current) }
        return items
    }

    /// Net count of `[` minus `]` outside string literals.
    private func bracketBalance(_ text: String) -> Int {
        var depth = 0
        var inString = false
        var escaped = false
        for c in text {
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "[" {
                depth += 1
            } else if c == "]" {
                depth -= 1
            }
        }
        return depth
    }

    /// Removes a trailing `# comment`, respecting quotes.
    private func stripComment(_ line: String) -> String {
        var inString = false
        var escaped = false
        var out = ""
        for c in line {
            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
                out.append(c)
            } else if c == "#" {
                break
            } else {
                out.append(c)
            }
        }
        return out
    }

    private mutating func warn(_ message: String, _ lineNo: Int) {
        let where_ = lineNo > 0 ? "\(path):\(lineNo): " : "\(path): "
        let text = "\(where_)\(message)"
        cfg.warnings.append(text)
        fputs("\(kAppName): config \(text)\n", stderr)
    }
}
