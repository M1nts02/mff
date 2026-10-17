import Cocoa

extension AppDelegate {

    // MARK: - Search

    /// Debounce for ordinary (path/name) and index-backed searches: wait until
    /// the user has stopped typing for this long before searching.
    static let searchDebounce: TimeInterval = 0.5

    func scheduleSearch(_ query: String) {
        if isContentSearch {
            scheduleContentSearch()
            return
        }
        // Periodically re-probe the daemon so it can appear/disappear without
        // restarting mff. If it went away, reload from a live walk.
        maybeReprobeIndex()
        // Index mode: the daemon narrows by query, so a change to the query
        // means a fresh fetch rather than an in-memory filter.
        if useIndex {
            if query != indexQuery {
                indexQuery = query
                searchTimer?.invalidate()
                searchTimer = Timer.scheduledTimer(withTimeInterval: AppDelegate.searchDebounce, repeats: false) { [weak self] _ in
                    self?.startLoadingData()
                }
            }
            return
        }
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: AppDelegate.searchDebounce, repeats: false) { [weak self] _ in
            self?.performSearch(query)
        }
    }

    /// Grep mode: don't match while the user is typing. Wait until the input has
    /// been idle for one second, then start the (streaming) content search.
    func scheduleContentSearch() {
        searchTimer?.invalidate()
        contentMatchTimer?.invalidate()
        contentMatchTimer = nil
        // Stop matching while typing, but keep the current result: the next
        // search reuses it when characters are only added.
        contentSearchActive = false
        searchGeneration += 1
        pendingContentMatches = 0
        searchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.startContentSearch()
        }
    }

    /// Runs the search immediately. Called from `finishStreaming` once the
    /// item list is complete, so its result is the final filtered set; `-1` is
    /// honoured there (not per batch, where an unsorted early hit could win).
    func applyQuery(_ query: String) {
        searchTimer?.invalidate()
        performSearch(query)
    }

    func performSearch(_ query: String) {
        if isContentSearch {
            startContentSearch()
            return
        }

        let generation = searchGeneration + 1
        searchGeneration = generation
        // Typing a few more characters only narrows the result set, so start
        // from the previous matches instead of rescanning every item. Items
        // that were filtered out can never match a longer query, so they are
        // skipped; the surviving ones are re-matched to refresh scores and
        // highlight positions.
        let reusable: [MatchResult]
        if FuzzyMatcher.canNarrow(from: lastQuery, to: query) {
            reusable = filteredMatches
        } else {
            reusable = []
        }
        // Enumerated so ties keep the previous (or original) order.
        let candidates: [(SearchableItem, Int)] = reusable.isEmpty
            ? allItems.enumerated().map { ($0.element, $0.offset) }
            : reusable.enumerated().map { ($0.element.item, $0.offset) }
        // App search matches only the app name; everything else matches the
        // whole path.
        let matchPath = !isAppSearch

        DispatchQueue.global(qos: .userInitiated).async {
            var results: [MatchResult]
            if query.isEmpty {
                results = candidates.map { MatchResult(item: $0.0, score: 0, termPositions: []) }
            } else {
                let matched = candidates.compactMap { pair -> MatchResult? in
                    FuzzyMatcher.match(query: query, in: pair.0, matchPath: matchPath)
                }
                let indexed = matched.enumerated().sorted { a, b in
                    if a.element.score != b.element.score {
                        return a.element.score > b.element.score
                    }
                    return a.offset < b.offset
                }
                results = indexed.map { $0.element }
            }

            DispatchQueue.main.async {
                guard generation == self.searchGeneration else { return }
                self.filteredMatches = results
                self.lastQuery = query
                self.tableView.reloadData()
                if !results.isEmpty {
                    self.selectRow(0)
                } else {
                    self.clearSelection()
                }
                self.updateFooter()
                // Interactive (typed) search: honour -1 on the final result,
                // and -m (print the query) when nothing matches.
                if !self.isStreaming { self.finishPlainSearch(query, results: results) }
            }
        }
    }
    /// Finishes a plain (non-content) search whose result set is final.
    ///
    /// With several matches only the selection is refreshed: the user may type
    /// on, and `-1` must not fire and quit in the middle of a search (neither
    /// when a streamed index result happens to be a single hit).
    func finishPlainSearch(_ query: String, results: [MatchResult]) {
        if results.count == 1, config.autoSelectSingle {
            selectCurrent()
        } else if results.isEmpty, config.returnQueryOnMismatch {
            writeOutput(query)
            exit(1)
        }
    }

    // MARK: - Highlighting

    /// One highlight colour per search term, so terms can be told apart.
    static let termHighlightColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemTeal, .systemBlue, .systemPurple, .systemPink
    ]

    /// Highlight indices (per search term) into the item's file name.
    func nameHighlightPositions(for item: SearchableItem, match: MatchResult) -> [[Int]] {
        let nameLen = item.displayName.count
        let nameStart = isAppSearch
            ? 0
            : max(0, item.lowerSearch.count - item.lowerDisplay.count)
        return match.termPositions.map { term in
            term.compactMap { p in
                let local = p - nameStart
                return (local >= 0 && local < nameLen) ? local : nil
            }
        }
    }

    /// Highlight indices (per search term) into the item's parent directory.
    func pathHighlightPositions(for item: SearchableItem, match: MatchResult) -> [[Int]] {
        guard !isAppSearch else { return [] }
        let parentLen = item.parentPath.count
        return match.termPositions.map { term in
            term.filter { $0 >= 0 && $0 < parentLen }
        }
    }

    func attributedText(_ text: String,
                                termHighlights: [[Int]],
                                color: NSColor,
                                font: NSFont) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: font
        ])
        guard termHighlights.contains(where: { !$0.isEmpty }) else { return attr }

        let count = text.count
        let bold = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.bold), size: font.pointSize) ?? font
        for (termIndex, positions) in termHighlights.enumerated() {
            let highlight = Self.termHighlightColors[termIndex % Self.termHighlightColors.count]
                .withAlphaComponent(0.38)
            for p in Set(positions) where p >= 0 && p < count {
                let idx = text.index(text.startIndex, offsetBy: p)
                let next = text.index(after: idx)
                let range = NSRange(idx..<next, in: text)
                attr.addAttribute(.font, value: bold, range: range)
                attr.addAttribute(.backgroundColor, value: highlight, range: range)
            }
        }
        return attr
    }

    /// Re-probes the daemon at most once every few seconds. Losing the daemon
    /// switches this run back to a live walk (and reloads the list).
    func maybeReprobeIndex() {
        guard wantsIndex else { return }
        let now = Date()
        if let last = lastIndexProbe, now.timeIntervalSince(last) < 5 { return }
        lastIndexProbe = now
        let was = useIndex
        refreshIndexAvailability()
        if was && !useIndex {
            indexQuery = ""
            startLoadingData()
        }
    }
}
