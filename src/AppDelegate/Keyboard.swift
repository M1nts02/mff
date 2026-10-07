import Cocoa

extension AppDelegate {

    // MARK: - Keyboard handling

    func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let key = event.keyCode
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Global Command shortcuts (work regardless of focus).
            let isCmd = mods.contains(.command)
                && !mods.contains(.control)
                && !mods.contains(.option)

            // Cmd+G: edit the search folder.
            if isCmd, key == 5 {
                self.togglePathEditing()
                return nil
            }

            // While picking a search folder, route keys to the folder picker.
            if self.isEditingPath {
                // Cmd+1..9: complete the Nth folder.
                if isCmd, !mods.contains(.shift), let index = commandDigitRowIndex(key) {
                    self.chooseRow(index)
                    return nil
                }
                switch key {
                case 53: self.endPathEditing(); return nil              // esc
                case 36, 76: self.commitPathEditing(); return nil       // return
                case 48, 124: self.completePickerSelection(); return nil // tab / right
                case 126: self.moveSelection(-1); return nil            // up
                case 125: self.moveSelection(1); return nil             // down
                case 116: self.moveSelectionByPage(-1); return nil      // page up
                case 121: self.moveSelectionByPage(1); return nil       // page down
                default: return event
                }
            }

            if isCmd {
                // Cmd+1..9: pick the Nth row directly (like choose-gui).
                if !mods.contains(.shift), let index = commandDigitRowIndex(key) {
                    self.chooseRow(index)
                    return nil
                }
                // Cmd+O: open the selected file with its default app.
                if !mods.contains(.shift), key == 31 {
                    self.openSelectedFile()
                    return nil
                }
                // Cmd+R: reveal the selected file in Finder.
                if !mods.contains(.shift), key == 15 {
                    self.revealSelectedFile()
                    return nil
                }
                // Cmd+M: mark/unmark the current file (multi-select).
                if !mods.contains(.shift), key == 46 {
                    self.toggleSelection(at: self.tableView.selectedRow)
                    return nil
                }
                // Cmd+Shift+M: clear every mark.
                if mods.contains(.shift), key == 46 {
                    self.clearAllMarks()
                    return nil
                }
                // Cmd+Shift+A: mark every row (multi-select). Works regardless
                // of whether the search field or the list has focus.
                if mods.contains(.shift), key == 0 {
                    self.markAllRows()
                    return nil
                }
                // Cmd+T: open the file-type selector (bottom-right).
                if !mods.contains(.shift), key == 17 {
                    self.openTypePopup()
                    return nil
                }
                // Cmd+Return: play / toggle auto-play of audio/video previews.
                if !mods.contains(.shift), key == 36 || key == 76 {
                    self.toggleAutoplay()
                    return nil
                }
            }

            let searchIsFirst = self.window.firstResponder === self.searchField.currentEditor()

            if searchIsFirst {
                switch key {
                case 126: self.moveSelection(-1, extend: mods.contains(.shift)); return nil
                case 125: self.moveSelection(1, extend: mods.contains(.shift)); return nil
                case 116: self.moveSelectionByPage(-1, extend: mods.contains(.shift)); return nil // page up
                case 121: self.moveSelectionByPage(1, extend: mods.contains(.shift)); return nil  // page down
                case 36, 76: self.selectCurrent(); return nil
                case 53:
                    if !self.searchField.stringValue.isEmpty {
                        self.searchField.stringValue = ""
                        self.applyQueryTags()
                        self.performSearch("")
                        return nil
                    } else {
                        self.cancel()
                        return nil
                    }
                case 48: // tab -> insert term separator
                    self.insertQuerySeparator()
                    return nil
                default:
                    if mods.contains(.control) {
                        if key == 35 || key == 40 { self.moveSelection(-1, extend: mods.contains(.shift)); return nil }
                        if key == 45 || key == 38 { self.moveSelection(1, extend: mods.contains(.shift)); return nil }
                        if key == 32 { self.moveSelectionByHalfPage(-1, extend: mods.contains(.shift)); return nil } // ctrl+u
                        if key == 2 { self.moveSelectionByHalfPage(1, extend: mods.contains(.shift)); return nil }   // ctrl+d
                        if key == 8 { self.cancel(); return nil } // ctrl+c
                    }
                    return event
                }
            } else {
                // list focused
                switch key {
                case 53: self.cancel(); return nil
                case 36, 76: self.selectCurrent(); return nil
                case 48: self.insertQuerySeparator(); return nil // tab -> separator
                case 125: // down
                    self.moveSelection(1, extend: mods.contains(.shift)); return nil
                case 126: // up
                    self.moveSelection(-1, extend: mods.contains(.shift)); return nil
                case 123, 124, 117:
                    return event // left / right / forward-delete handled natively by the table
                case 116: self.moveSelectionByPage(-1, extend: mods.contains(.shift)); return nil // page up
                case 121: self.moveSelectionByPage(1, extend: mods.contains(.shift)); return nil  // page down
                case 115: self.selectRow(0); return nil            // home
                case 119: self.selectRow(self.displayedItemCount - 1); return nil // end
                default:
                    if self.isPrintable(event) {
                        let chars = event.characters ?? ""
                        self.searchField.stringValue += chars
                        self.focusSearch()
                        self.scheduleSearch(self.searchField.stringValue)
                        return nil
                    }
                    return event
                }
            }
        }
    }

    func isPrintable(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.control) || mods.contains(.option) {
            return false
        }
        guard let chars = event.characters, !chars.isEmpty else { return false }
        // Function keys (arrows, home, end, etc.) live in the Unicode
        // private-use range; they should not be redirected to the search field.
        if let first = chars.unicodeScalars.first, first.value >= 0xF700 && first.value <= 0xF8FF {
            return false
        }
        return true
    }

    func installClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.isDragging else { return }
            let point = NSEvent.mouseLocation
            if self.window.frame.contains(point) { return }
            NSApp.terminate(nil)
        }
    }

    func installFocusObserver() {
        window.delegate = self
    }

    /// Use a field editor that draws rounded tag backgrounds.
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        if let field = client as? NSSearchField, field === searchField {
            return tagFieldEditor
        }
        return nil
    }

    @objc func windowDidResignKey(_ notification: Notification) {
        // While a drag is in progress the panel naturally resigns key as the
        // drop target (e.g. Finder) becomes active; do not terminate mid-drag.
        guard !isDragging else { return }
        NSApp.terminate(nil)
    }
}
