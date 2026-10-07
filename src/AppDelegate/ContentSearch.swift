import Cocoa

extension AppDelegate {

    // MARK: - Content search (streaming)

    /// Content mode: stream matches incrementally, so a large tree fills the
    /// list while it is still being scanned. Called once the input has been idle
    /// for a second (see `scheduleContentSearch`).
    ///
    /// The previous result is reused when the query only *grows* (characters
    /// added): the next candidates are the files that matched last time plus any
    /// that were never checked. Deleting or editing characters drops the result
    /// and re-checks every file.
    func startContentSearch() {
        searchTimer?.invalidate()
        contentMatchTimer?.invalidate()
        contentMatchTimer = nil
        searchGeneration += 1

        let query = searchField.stringValue
        let previousMatched = filteredMatches.map { $0.item }
        let untested = contentCursor < contentCandidates.count
            ? Array(contentCandidates[contentCursor...])
            : []
        let reuse = !query.isEmpty && FuzzyMatcher.canNarrow(from: lastContentQuery, to: query)

        filteredMatches.removeAll()
        pendingContentMatches = 0
        tableView.reloadData()
        clearSelection()

        if query.isEmpty {
            contentSearchActive = false
            contentCandidates = []
            contentCursor = 0
            lastContentQuery = ""
            filteredMatches = allItems.map { MatchResult(item: $0, score: 0, termPositions: []) }
            tableView.reloadData()
            if !filteredMatches.isEmpty { selectRow(0) } else { updatePreview() }
            updateFooter()
            autoSelectIfSingle()
            return
        }

        if reuse {
            // A longer query can only match files that matched the shorter one,
            // plus any that were never checked. De-duplicate because a flushed
            // batch may also still be counted as untested.
            var seen = Set<Int>()
            var candidates: [SearchableItem] = []
            for item in previousMatched + untested where seen.insert(item.id).inserted {
                candidates.append(item)
            }
            contentCandidates = candidates
        } else {
            contentCandidates = allItems
        }
        contentCursor = 0
        lastContentQuery = query
        contentSearchActive = true
        matchPendingContent()
        updateFooter()
        finalizeContentSearchIfIdle()
    }

    /// Coalesces bursty batches while a content search is streaming: schedules
    /// at most one match pass at a time using a dedicated timer so it never
    /// disturbs the idle/typing debounce.
    func scheduleContentMatch() {
        guard contentSearchActive else { return }
        guard contentMatchTimer == nil else { return }
        contentMatchTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.contentMatchTimer = nil
            self.matchPendingContent()
        }
    }

    /// Matches one batch of not-yet-checked candidates, streaming results to the
    /// list, then continues with anything that arrived meanwhile. The cursor is
    /// advanced only once a batch completes, so an interrupted batch is left
    /// "untested" and can be reused by a later, longer query.
    func matchPendingContent() {
        guard isContentSearch, contentSearchActive else { return }
        guard pendingContentMatches == 0 else { return }
        let query = searchField.stringValue
        guard !query.isEmpty else { return }

        let start = contentCursor
        let end = min(start + 256, contentCandidates.count)
        guard end > start else { return }
        let slice = Array(contentCandidates[start..<end])
        let generation = searchGeneration
        pendingContentMatches += 1

        contentMatchQueue.async { [weak self] in
            var pending: [MatchResult] = []
            pending.reserveCapacity(64)

            func flush() {
                guard !pending.isEmpty else { return }
                let chunk = pending
                pending.removeAll(keepingCapacity: true)
                DispatchQueue.main.async {
                    guard let self, generation == self.searchGeneration else { return }
                    self.filteredMatches.append(contentsOf: chunk)
                    self.tableView.reloadData()
                    if self.tableView.selectedRow < 0 {
                        self.selectRow(0)
                    }
                    self.updateFooter()
                }
            }

            for item in slice {
                if let match = FuzzyMatcher.matchContent(query: query, in: item) {
                    pending.append(match)
                    if pending.count >= 64 { flush() }
                }
            }
            flush()

            DispatchQueue.main.async {
                guard let self, generation == self.searchGeneration else { return }
                self.contentCursor = end
                self.pendingContentMatches -= 1
                self.finalizeContentSearchIfIdle()
                self.matchPendingContent()
            }
        }
    }

    /// Once a pass has drained and indexing has finished, honour `-1`
    /// (auto-select a single remaining match).
    func finalizeContentSearchIfIdle() {
        guard isContentSearch, contentSearchActive, !isStreaming, pendingContentMatches == 0,
              contentCursor >= contentCandidates.count else { return }
        autoSelectIfSingle()
    }

    /// Auto-selects the only match when `-1` is set; used both for a matching
    /// content search and for the plain (empty-query) file list.
    func autoSelectIfSingle() {
        guard config.autoSelectSingle, filteredMatches.count == 1,
              let item = filteredMatches.first?.item else { return }
        performEnter(on: item)
        exit(0)
    }
}
