import Cocoa

extension AppDelegate {

    // MARK: - Selection

    var displayedItemCount: Int {
        isEditingPath ? pickerItems.count : filteredMatches.count
    }

    /// Selects a single row, clearing any marks (fresh selection).
    func selectRow(_ index: Int) {
        guard index >= 0, index < displayedItemCount else { return }
        multiSelection.removeAll()
        selectionAnchor = index
        applyTableSelection(index)
    }

    /// Moves the active (cursor) row without disturbing marked rows, so ⌘M
    /// marks persist while navigating with the arrow keys.
    func moveCursor(to index: Int) {
        guard index >= 0, index < displayedItemCount else { return }
        selectionAnchor = index
        applyTableSelection(index)
    }

    /// Applies the active (accent-highlighted) row and keeps the secondary
    /// multi-selection highlight in sync.
    func applyTableSelection(_ index: Int) {
        guard index >= 0, index < displayedItemCount else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        updatePreview()
        updateRevealButton()
        updateClearMarksButton()
        refreshRowSelectionDisplay()
    }

    /// Finder-style range extension: selection becomes the contiguous range from
    /// the anchor to `index`, and `index` becomes the active row.
    func extendSelection(to index: Int) {
        let count = displayedItemCount
        guard count > 0, index >= 0, index < count else { return }
        let anchor = max(selectionAnchor ?? tableView.selectedRow, 0)
        let lower = min(anchor, index)
        let upper = max(anchor, index)
        multiSelection = Set(lower...upper)
        selectionAnchor = anchor
        applyTableSelection(index)
    }

    /// Cmd+click / Cmd+M: toggles an individual row's mark in the selection.
    func toggleSelection(at index: Int) {
        guard multiSelectEnabled, index >= 0, index < displayedItemCount else { return }
        if multiSelection.contains(index) {
            multiSelection.remove(index)
        } else {
            multiSelection.insert(index)
        }
        selectionAnchor = index
        applyTableSelection(index)
    }

    /// Cmd+Shift+M: clear every mark, falling back to the active row.
    func clearAllMarks() {
        guard multiSelectEnabled else { return }
        multiSelection.removeAll()
        selectionAnchor = tableView.selectedRow >= 0 ? tableView.selectedRow : nil
        updateRevealButton()
        updateClearMarksButton()
        refreshRowSelectionDisplay()
    }

    /// Cmd+Shift+A: mark every row in the current list (the active row is kept
    /// in place). Cmd+A alone stays bound to the search field's "select all text".
    func markAllRows() {
        guard multiSelectEnabled else { return }
        let count = displayedItemCount
        guard count > 0 else { return }
        multiSelection = Set(0..<count)
        selectionAnchor = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
        updateRevealButton()
        updateClearMarksButton()
        refreshRowSelectionDisplay()
    }

    func clearSelection() {
        multiSelection.removeAll()
        selectionAnchor = nil
        tableView.deselectAll(nil)
        updateRevealButton()
        updateClearMarksButton()
    }

    func refreshRowSelectionDisplay() {
        tableView.enumerateAvailableRowViews { view, row in
            (view as? SpotlightRowView)?.isMultiSelected =
                self.multiSelectEnabled && self.multiSelection.contains(row)
        }
    }

    func moveSelection(_ offset: Int, extend: Bool = false) {
        let count = displayedItemCount
        guard count > 0 else { return }
        let current = tableView.selectedRow
        var next = current + offset
        if next < 0 { next = 0 }
        if next >= count { next = count - 1 }
        if extend && multiSelectEnabled {
            extendSelection(to: next)
        } else {
            moveCursor(to: next)
        }
    }

    func moveSelectionByPage(_ direction: Int, extend: Bool = false) {
        moveSelection(direction * max(1, config.numRows), extend: extend)
    }

    func moveSelectionByHalfPage(_ direction: Int, extend: Bool = false) {
        moveSelection(direction * max(1, config.numRows / 2), extend: extend)
    }

    func chooseRow(_ index: Int) {
        if isEditingPath {
            guard pickerItems.indices.contains(index) else { return }
            selectRow(index)
            completePickerSelection()
            return
        }
        guard filteredMatches.indices.contains(index) else { return }
        selectRow(index)
        selectCurrent()
    }

    @objc func handleClick() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        if isEditingPath {
            // Left-click a folder to select and complete (descend into) it.
            guard pickerItems.indices.contains(row) else { return }
            selectRow(row)
            completePickerSelection()
            return
        }
        guard filteredMatches.indices.contains(row) else { return }

        if multiSelectEnabled {
            let event = NSApp.currentEvent
            let mods = event?.modifierFlags ?? []
            let clickCount = event?.clickCount ?? 1
            if mods.contains(.command) {
                toggleSelection(at: row)
                return
            }
            if mods.contains(.shift) {
                extendSelection(to: row)
                return
            }
            if clickCount >= 2 {
                selectRow(row)
                selectCurrent()
                return
            }
            // A plain click only moves the active row; it does not accept.
            selectRow(row)
            return
        }

        selectRow(row)
        selectCurrent()
    }

    func itemForRow(_ row: Int) -> SearchableItem? {
        if isEditingPath {
            return pickerItems.indices.contains(row) ? pickerItems[row] : nil
        }
        return filteredMatches.indices.contains(row) ? filteredMatches[row].item : nil
    }

    /// Rows to act on: every marked row when any exist, otherwise the
    /// active (cursor) row.
    func selectedRows() -> [Int] {
        if !multiSelection.isEmpty {
            return multiSelection.sorted()
        }
        let row = tableView.selectedRow
        return (row >= 0 && row < displayedItemCount) ? [row] : []
    }

    func emit(_ item: SearchableItem) {
        if config.outputIndex {
            writeOutput(String(item.id))
        } else {
            writeOutput(item.raw)
        }
    }

    /// Opens every selected item with its own default application, so a mix of
    /// file types opens correctly (images in Preview, audio in Music, etc.).
    func openItems(_ items: [SearchableItem]) {
        for item in items {
            if let url = item.url {
                NSWorkspace.shared.open(url)
            } else {
                emit(item)
            }
        }
    }

    /// Accepts a multi-selection: opens all files for `--enter open`/Open, and
    /// otherwise prints every selected item (newline- or NUL-separated).
    /// Reveal-in-Finder is intentionally not offered for multi-selections.
    func acceptMultiple(_ items: [SearchableItem]) {
        guard !items.isEmpty else {
            if config.returnQueryOnMismatch {
                writeOutput(searchField.stringValue)
                exit(0)
            }
            exit(1)
        }
        if config.enterAction == .open {
            openItems(items)
        } else {
            for item in items { emit(item) }
        }
    }

    /// Applies the configured Enter behaviour; for `path` it prints the item.
    /// Items without a URL (stdin lines) always print.
    func performEnter(on item: SearchableItem) {
        if let url = item.url {
            switch config.enterAction {
            case .open:
                NSWorkspace.shared.open(url)
                return
            case .reveal:
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return
            case .printPath:
                break
            }
        }
        emit(item)
    }

    func selectCurrent() {
        let items = selectedRows().compactMap { itemForRow($0) }
        guard !items.isEmpty else {
            if config.returnQueryOnMismatch {
                writeOutput(searchField.stringValue)
                exit(0)
            }
            exit(1)
        }
        if items.count > 1 {
            acceptMultiple(items)
        } else {
            performEnter(on: items[0])
        }
        exit(0)
    }

    /// Cmd+O: open the selected file(s) with their default applications.
    func openSelectedFile() {
        let urls = selectedRows().compactMap { itemForRow($0) }.compactMap { $0.url }
        guard !urls.isEmpty else { return }
        for url in urls { NSWorkspace.shared.open(url) }
        exit(0)
    }

    /// Cmd+T: open the file-type popup so it can be changed from the keyboard.
    func openTypePopup() {
        typePopup?.performClick(nil)
    }

    /// Cmd+R: reveal the selected file in Finder. Not offered while several
    /// items are selected (the footer button is disabled in that state).
    func revealSelectedFile() {
        guard !hasMultiSelection else {
            NSSound.beep()
            return
        }
        guard let item = selectedRows().compactMap({ itemForRow($0) }).first,
              let url = item.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        exit(0)
    }

    func cancel() {
        if config.returnQueryOnMismatch {
            writeOutput(searchField.stringValue)
            exit(0)
        }
        exit(1)
    }

    func writeOutput(_ string: String) {
        var output = string
        output += config.outputNUL ? "\u{0}" : "\n"
        FileHandle.standardOutput.write(Data(output.utf8))
        fflush(stdout)
    }
}
