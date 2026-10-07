import Cocoa

extension AppDelegate {

    // MARK: - Search

    func scheduleSearch(_ query: String) {
        if isContentSearch {
            scheduleContentSearch()
            return
        }
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: false) { [weak self] _ in
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
        let items = allItems
        // App search matches only the app name; everything else matches the
        // whole path.
        let matchPath = !isAppSearch

        DispatchQueue.global(qos: .userInitiated).async {
            var results: [MatchResult]
            if query.isEmpty {
                results = items.map { MatchResult(item: $0, score: 0, termPositions: []) }
            } else {
                let matched = items.compactMap {
                    FuzzyMatcher.match(query: query, in: $0, matchPath: matchPath)
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
                self.tableView.reloadData()
                if !results.isEmpty {
                    self.selectRow(0)
                } else {
                    self.clearSelection()
                }
                self.updateFooter()

                if self.config.autoSelectSingle && !self.isStreaming && results.count == 1 {
                    self.selectCurrent()
                }
            }
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
}
