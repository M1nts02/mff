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
