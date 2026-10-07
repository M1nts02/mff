import Cocoa

extension AppDelegate {

    // MARK: - Search-folder editor

    func setupPathEditor() {
        guard isFileSearch, let container = window.contentView else { return }

        let icon = NSImageView(frame: searchIcon?.frame ?? .zero)
        icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        icon.contentTintColor = .controlAccentColor
        icon.isHidden = true
        container.addSubview(icon)
        pathIcon = icon

        let field = NSTextField(frame: searchField.frame)
        field.delegate = self
        field.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        field.textColor = .labelColor
        field.drawsBackground = false
        field.isBezeled = false
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "Search folder"
        field.autoresizingMask = [.width]
        field.isHidden = true
        container.addSubview(field)
        pathField = field
    }

    func beginPathEditing() {
        guard isFileSearch, !isEditingPath,
              let pathField, let pathIcon else { return }
        isEditingPath = true
        pickerPaths.removeAll()
        pickerItems.removeAll()
        clearSelection()

        var seed = config.searchPaths.first ?? FileManager.default.currentDirectoryPath
        seed = (seed as NSString).expandingTildeInPath
        if !(seed as NSString).isAbsolutePath {
            seed = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(seed)
        }
        seed = (seed as NSString).standardizingPath
        let displaySeed = seed.hasSuffix("/") ? seed : seed + "/"
        pathField.stringValue = displaySeed
        searchField.isHidden = true
        searchIcon?.isHidden = true
        pathIcon.isHidden = false
        pathField.isHidden = false
        // Keep focus in the path field: clicking the list must not steal it.
        tableView.refusesFirstResponder = true
        setPreviewPaneVisible(false)

        window.makeFirstResponder(pathField)
        if let editor = pathField.currentEditor() {
            editor.selectedRange = NSRange(location: (displaySeed as NSString).length, length: 0)
        }
        updatePicker()
    }

    func endPathEditing() {
        isEditingPath = false
        pathField?.isHidden = true
        pathIcon?.isHidden = true
        pickerPaths.removeAll()
        pickerItems.removeAll()
        tableView.refusesFirstResponder = false
        searchIcon?.isHidden = false
        searchField.isHidden = false
        setPreviewPaneVisible(true)

        window.makeFirstResponder(searchField)
        tableView.reloadData()
        if !filteredMatches.isEmpty {
            selectRow(0)
        } else {
            updatePreview()
        }
        updateFooter()
    }

    func togglePathEditing() {
        if isEditingPath {
            endPathEditing()
        } else {
            beginPathEditing()
        }
    }

    func commitPathEditing() {
        guard isEditingPath, let pathField else { return }
        let raw = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (raw as NSString).expandingTildeInPath

        var isDir: ObjCBool = false
        guard !expanded.isEmpty,
              FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
              isDir.boolValue else {
            NSSound.beep()
            return
        }

        config.searchPaths = [expanded]
        allItems.removeAll()
        filteredMatches.removeAll()
        previewedURL = nil

        endPathEditing()
        startLoadingData()
        updateFooter()
    }

    /// Lists the folders under the path currently typed in the picker.
    func updatePicker() {
        guard isEditingPath, let pathField else { return }

        pickerPaths = PathCompleter.directoryCompletions(
            for: pathField.stringValue,
            includeHidden: config.includeHidden
        )
        pickerItems = pickerPaths.map {
            SearchableItem(url: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath), isDirectory: true)
        }
        tableView.reloadData()
        if !pickerItems.isEmpty {
            selectRow(0)
        }
        updateFooter()
    }

    /// Completes the highlighted folder: descends into it and refreshes the list.
    func completePickerSelection() {
        guard isEditingPath, let pathField else { return }
        let row = tableView.selectedRow
        guard pickerPaths.indices.contains(row) else { return }
        let value = pickerPaths[row]
        pathField.stringValue = value
        if let editor = pathField.currentEditor() {
            editor.selectedRange = NSRange(location: (value as NSString).length, length: 0)
        }
        updatePicker()
    }
}
