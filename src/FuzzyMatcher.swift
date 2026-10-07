import Foundation

/// Fuzzy matcher used by every mode.
///
/// Search terms are separated by **Tab**. Spaces are ordinary characters, so a
/// term may contain spaces.
///
/// Every term must match (logical AND). Terms are matched against the whole
/// path for file/stdin items, or just the file name for `--app` so app search
/// stays free of path noise.
///
///   plain text  fuzzy subsequence anywhere in the target
///   'text       exact substring anywhere in the target
///   .ext        file-extension filter (multi-part like .tar.gz works too)
///   ^text       file name starts with text
///   text$       file name ends with text
///   !term       exclude anything matching term
enum FuzzyMatcher {

    /// Character the Tab key inserts into the query field. It renders as a
    /// blank gap and marks a term boundary; the coloured tags show the terms.
    static let termSeparator: Character = "\u{2003}" // EM SPACE

    /// Splits a query into terms on Tab (or the separator character). Spaces
    /// are ordinary characters and stay inside a term.
    static func tokenize(_ query: String) -> [String] {
        query
            .split(whereSeparator: { $0 == "\t" || $0 == termSeparator })
            .map(String.init)
    }

    /// Whether a content search for `new` may reuse the files skipped by `old`.
    ///
    /// True only when `new` is `old` with characters appended and the change is
    /// monotonic (a longer query is strictly narrower): a whole new term is
    /// added, or a plain / `'exact` / `^prefix` positive term is extended.
    /// Suffix (`text$`), extension (`.ext`) and negation (`!term`) terms are not
    /// monotonic under extension, so they force a full re-match.
    static func canNarrow(from old: String, to new: String) -> Bool {
        guard !old.isEmpty, new.hasPrefix(old), new.count > old.count else { return false }
        let appended = new[new.index(new.startIndex, offsetBy: old.count)...]
        // A new term leaves every old term untouched, so old skips still hold.
        if appended.first == termSeparator || appended.first == "\t" {
            return true
        }
        // Extending the last term must not introduce an operator.
        if appended.contains(where: { "!$^.'".contains($0) }) { return false }
        let lastOld = tokenize(old).last ?? ""
        if lastOld.hasPrefix("!") || lastOld.hasSuffix("$")
            || (lastOld.hasPrefix(".") && lastOld.count > 1) {
            return false
        }
        return true
    }

    /// - Parameter matchPath: `true` matches the whole path (the default for
    ///   file/stdin search); `false` matches only the file name (used by `--app`).
    static func match(query: String, in item: SearchableItem, matchPath: Bool = true) -> MatchResult? {
        let tokens = tokenize(query)
        if tokens.isEmpty {
            return MatchResult(item: item, score: 0, termPositions: [])
        }

        let targetString = matchPath ? item.lowerSearch : item.lowerDisplay
        let target = Array(targetString)
        let nameStart = matchPath ? max(0, item.lowerSearch.count - item.lowerDisplay.count) : 0

        var total = 0
        var termPositions: [[Int]] = []

        for token in tokens {
            var body = token
            var negate = false
            if body.hasPrefix("!") {
                negate = true
                body.removeFirst()
            }
            if body.isEmpty { continue }

            // .ext -> extension filter
            if body.hasPrefix("."), body.count > 1 {
                let want = String(body.dropFirst()).lowercased()
                let suffix = "." + want
                let ok = item.fileExtension == want || targetString.hasSuffix(suffix)
                if negate {
                    if ok { return nil }
                } else {
                    if !ok { return nil }
                    total += 200
                    if targetString.hasSuffix(suffix) {
                        termPositions.append(Array((target.count - suffix.count)..<target.count))
                    } else {
                        termPositions.append([])
                    }
                }
                continue
            }

            // ^text -> file name starts with
            if body.hasPrefix("^") {
                let t = Array(body.dropFirst().lowercased())
                if t.isEmpty { continue }
                let name = Array(item.lowerDisplay)
                let ok = name.count >= t.count && Array(name.prefix(t.count)) == t
                if negate {
                    if ok { return nil }
                } else {
                    if !ok { return nil }
                    total += 180
                    termPositions.append(Array(nameStart..<(nameStart + t.count)))
                }
                continue
            }

            // text$ -> file name ends with
            if body.hasSuffix("$") {
                let t = Array(body.dropLast().lowercased())
                if t.isEmpty { continue }
                let name = Array(item.lowerDisplay)
                let ok = name.count >= t.count && Array(name.suffix(t.count)) == t
                if negate {
                    if ok { return nil }
                } else {
                    if !ok { return nil }
                    total += 180
                    termPositions.append(Array((nameStart + name.count - t.count)..<(nameStart + name.count)))
                }
                continue
            }

            // 'text -> exact substring, otherwise fuzzy subsequence, in the target
            let isExact = body.hasPrefix("'")
            let text = isExact ? String(body.dropFirst()) : body
            let t = Array(text.lowercased())
            if t.isEmpty { continue }

            let result: (score: Int, positions: [Int])? = isExact
                ? exact(t, in: target)
                : fuzzy(t, in: target)
            if negate {
                if result != nil { return nil }
            } else {
                guard let result else { return nil }
                total += result.score
                termPositions.append(result.positions)
            }
        }

        return MatchResult(item: item, score: total, termPositions: termPositions)
    }

    // MARK: - Match modes

    /// Content-search matching (content mode).
    ///
    /// Every term must match the file in one of two ways (logical AND):
    ///   - first the file path/name, using the same rules as file mode (fuzzy
    ///     or `'exact`); only when that fails,
    ///   - the file contents, as a case-insensitive substring.
    ///
    /// A term that matches the path/name never searches the contents, and a
    /// content search stops at the first hit (`range` returns the first
    /// occurrence). Binary files and files above `--max-filesize` have no
    /// indexed contents, so they are skipped for content matching but are still
    /// matched by name/path. `.ext` filters by extension and `^`/`$` by file
    /// name; `!` negates both sources. When a term matches the path/name its
    /// positions are returned so the row can highlight it; content-only matches
    /// contribute no name/path highlights.
    static func matchContent(query: String, in item: SearchableItem) -> MatchResult? {
        let tokens = tokenize(query)
        if tokens.isEmpty {
            return MatchResult(item: item, score: 0, termPositions: [])
        }

        let content = item.content ?? ""
        let target = Array(item.lowerSearch)
        let nameStart = max(0, item.lowerSearch.count - item.lowerDisplay.count)
        var total = 0
        var termPositions: [[Int]] = []

        for token in tokens {
            var body = token
            var negate = false
            if body.hasPrefix("!") {
                negate = true
                body.removeFirst()
            }
            if body.isEmpty { continue }

            // .ext -> extension filter
            if body.hasPrefix("."), body.count > 1 {
                let want = String(body.dropFirst()).lowercased()
                let suffix = "." + want
                let ok = item.fileExtension == want || item.lowerSearch.hasSuffix(suffix)
                if negate {
                    if ok { return nil }
                } else {
                    if !ok { return nil }
                    total += 200
                    if item.lowerSearch.hasSuffix(suffix) {
                        termPositions.append(Array((target.count - suffix.count)..<target.count))
                    } else {
                        termPositions.append([])
                    }
                }
                continue
            }

            // ^text -> file name starts with
            if body.hasPrefix("^") {
                let t = Array(body.dropFirst().lowercased())
                if t.isEmpty { continue }
                let name = Array(item.lowerDisplay)
                let ok = name.count >= t.count && Array(name.prefix(t.count)) == t
                if negate {
                    if ok { return nil }
                } else {
                    if !ok { return nil }
                    total += 180
                    termPositions.append(Array(nameStart..<(nameStart + t.count)))
                }
                continue
            }

            // text$ -> file name ends with
            if body.hasSuffix("$") {
                let t = Array(body.dropLast().lowercased())
                if t.isEmpty { continue }
                let name = Array(item.lowerDisplay)
                let ok = name.count >= t.count && Array(name.suffix(t.count)) == t
                if negate {
                    if ok { return nil }
                } else {
                    if !ok { return nil }
                    total += 180
                    termPositions.append(Array((nameStart + name.count - t.count)..<(nameStart + name.count)))
                }
                continue
            }

            // Plain (or 'exact) term -> the file path (same rules as file
            // mode) OR a case-insensitive substring of the contents. Binary and
            // oversized files have no contents but still match on the path.
            let isExact = body.hasPrefix("'")
            let text = isExact ? String(body.dropFirst()) : body
            let t = Array(text.lowercased())
            if t.isEmpty { continue }

            let pathResult: (score: Int, positions: [Int])? = isExact
                ? exact(t, in: target)
                : fuzzy(t, in: target)

            // Path/name matches take priority: only fall back to searching the
            // contents when the term did not match the path. A content search
            // stops at the first hit and marks the term as satisfied.
            if negate {
                if pathResult != nil { return nil }
                if content.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    return nil
                }
            } else if let pr = pathResult {
                total += pr.score
                termPositions.append(pr.positions)
            } else if let contentHit = content.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) {
                // Earlier content matches rank a little higher; bounded so the
                // score stays cheap to compute on large contents.
                let offset = content.distance(from: content.startIndex, to: contentHit.lowerBound)
                total += 120 + max(0, 60 - min(offset / 32, 60))
                termPositions.append([])
            } else {
                return nil
            }
        }

        return MatchResult(item: item, score: total, termPositions: termPositions)
    }

    private static func exact(_ t: [Character], in s: [Character]) -> (Int, [Int])? {
        let m = t.count, n = s.count
        guard m > 0, m <= n else { return nil }
        for i in 0...(n - m) {
            var ok = true
            for j in 0..<m where s[i + j] != t[j] {
                ok = false
                break
            }
            if ok {
                let positions = Array(i..<(i + m))
                let score = 200 + (i == 0 ? 40 : 0)
                return (score, positions)
            }
        }
        return nil
    }

    private static func fuzzy(_ t: [Character], in s: [Character]) -> (Int, [Int])? {
        let m = t.count, n = s.count
        guard m > 0, m <= n else { return nil }

        var positions: [Int] = []
        positions.reserveCapacity(m)
        var score = 0
        var idx = 0

        for (qi, tc) in t.enumerated() {
            var found = -1
            var j = idx
            while j < n {
                if s[j] == tc {
                    found = j
                    break
                }
                j += 1
            }
            if found < 0 { return nil }
            positions.append(found)

            var bonus = 16
            if found == 0 {
                bonus += 32
            } else {
                let prev = s[found - 1]
                if isSeparator(prev) { bonus += 24 }
                if prev.isLowercase && s[found].isUppercase { bonus += 24 }
            }
            if qi > 0 && found == positions[qi - 1] + 1 {
                bonus += 20
            }
            if qi > 0 {
                let gap = found - positions[qi - 1] - 1
                if gap > 0 {
                    score -= gap * 2 + (gap > 1 ? 4 : 0)
                }
            }
            score += bonus
            idx = found + 1
        }

        return (score, positions)
    }

    private static func isSeparator(_ c: Character) -> Bool {
        if c.isWhitespace { return true }
        if " /\\.,-_:;()[]{}!@#$%^&*+=<>?|~".contains(c) { return true }
        return false
    }
}
