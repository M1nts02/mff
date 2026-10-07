import Cocoa
import Quartz
import AVKit
import AVFoundation

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource,
                         NSTableViewDelegate, NSSearchFieldDelegate,
                         NSWindowDelegate {

    var config: Config

    // UI
    var window: NSPanel!
    var tableView: NSTableView!
    var scrollView: NSScrollView!
    var searchField: NSSearchField!
    var footerLabel: NSTextField!
    var typePopup: NSPopUpButton?
    var keyMonitor: Any?
    var clickMonitor: Any?

    // Search-folder picker (⌘G)
    var isEditingPath = false
    var searchIcon: NSImageView?
    var pathIcon: NSImageView?
    var pathField: NSTextField?
    var pickerPaths: [String] = []
    var pickerItems: [SearchableItem] = []

    // Data
    var allItems: [SearchableItem] = []
    var filteredMatches: [MatchResult] = []

    // Multi-selection (Finder-style shift+arrows / Cmd+A). Indices are rows in
    // the currently displayed list; the table's own selection is the active row.
    var multiSelection: Set<Int> = []
    var selectionAnchor: Int?
    var revealButton: NSButton?
    var clearMarksButton: NSButton?
    var isStreaming = false
    var isDragging = false
    var loadGeneration = 0
    var searchGeneration = 0
    var searchTimer: Timer?
    var reloadTimer: Timer?
    // Content mode streams matches incrementally after a short idle delay.
    var pendingContentMatches = 0
    var contentSearchActive = false
    var contentMatchTimer: Timer?
    var contentCandidates: [SearchableItem] = []
    var contentCursor = 0
    var lastContentQuery = ""
    let contentMatchQueue = DispatchQueue(label: "mff.content-match", qos: .userInitiated)

    // Embedded preview: Quick Look for documents/images, AVPlayer for media,
    // plus an artwork view for audio cover art.
    var previewView: QLPreviewView?
    var playerView: AVPlayerView?
    var artworkView: NSImageView?
    /// Text / artwork labels shown below the audio artwork: title, then a
    /// secondary line (artist) and a tertiary line (album).
    var audioTitleLabel: NSTextField?
    var audioArtistLabel: NSTextField?
    var audioAlbumLabel: NSTextField?
    /// Metadata currently shown in the audio preview (nil until loaded).
    var audioMetadata: AudioMetadata?
    var previewDivider: NSBox?
    var previewFrame: NSRect = .zero
    /// Plain-text preview for lyrics / subtitle files.
    var textPreviewScroll: NSScrollView?
    var textPreviewView: NSTextView?
    /// Custom field editor so query tags get rounded backgrounds.
    lazy var tagFieldEditor: NSTextView = makeTagFieldEditor()
    var previewedURL: URL?
    var artworkToken = 0

    // Layout constants
    let searchHeight: CGFloat = 56
    let rowHeight: CGFloat = 40
    let footerHeight: CGFloat = 44
    let previewWidth: CGFloat = 360

    /// File types offered by the footer popup (note: no "app" — use --app).
    static let typeChoices: [(title: String, category: FileCategory?)] = [
        ("All Types", nil),
        ("Images", .image),
        ("Videos", .video),
        ("Audio", .audio),
        ("Documents", .document),
        ("Text", .text),
        ("Archives", .archive),
        ("Folders", .folder)
    ]

    var isFileSearch: Bool { config.mode == .files || config.mode == .content }
    var isContentSearch: Bool { config.mode == .content }
    var isAppSearch: Bool { config.mode == .apps }
    var isStdin: Bool { config.mode == .stdin }

    var showsPreview: Bool {
        // App search is a compact launcher; it does not need a preview pane.
        return isFileSearch && !config.noPreview
    }

    /// Multi-select is available everywhere except app search.
    var multiSelectEnabled: Bool {
        config.multi && !isAppSearch
    }

    /// True once more than one row is part of the selection. Finder-style
    /// reveal-in-Finder does not make sense for a multi-selection, so it is
    /// disabled in that state.
    var hasMultiSelection: Bool {
        multiSelectEnabled && multiSelection.count > 1
    }

    init(config: Config) {
        self.config = config
        super.init()
    }

    // MARK: - Application lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        setupWindow()
        setupSearchField()
        setupTable()
        setupPreview()
        setupFooter()
        setupPathEditor()
        installKeyMonitor()
        installClickMonitor()
        installFocusObserver()

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)

        if !config.initialQuery.isEmpty {
            searchField.stringValue = config.initialQuery
            if let editor = searchField.currentEditor() {
                editor.selectedRange = NSRange(location: config.initialQuery.count, length: 0)
            }
            applyQueryTags()
        }

        startLoadingData()
        updateFooter()
    }

    /// Invisible menu bar so Cmd+C/X/V/A/Z work inside the search field.
    func setupMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(NSMenuItem.separator())
        edit.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")
        appItem.submenu = edit

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Window / UI setup

    func setupWindow() {
        guard let screen = NSScreen.main else { exit(1) }
        let screenFrame = screen.visibleFrame

        let screenMax = screenFrame.width - 40
        let requested = max(config.windowWidth, 400)
        let width: CGFloat
        if showsPreview {
            width = min(requested + previewWidth, screenMax)
        } else {
            width = min(requested, screenMax)
        }
        let height = searchHeight + rowHeight * CGFloat(config.numRows) + footerHeight

        let origin = NSPoint(
            x: screenFrame.midX - width / 2,
            y: screenFrame.midY - height / 2 + 110
        )

        window = CommandPalettePanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.hidesOnDeactivate = false
        window.appearance = nil

        let contentFrame = NSRect(x: 0, y: 0, width: width, height: height)

        let effect = NSVisualEffectView(frame: contentFrame)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor

        window.contentView = effect
    }

    func setupSearchField() {
        guard let container = window.contentView else { return }
        let width = container.bounds.width
        let height = container.bounds.height
        let top = height - searchHeight // search area occupies the top of the window

        let iconSize: CGFloat = 22
        let icon = NSImageView(frame: NSRect(
            x: 14,
            y: top + (searchHeight - iconSize) / 2,
            width: iconSize,
            height: iconSize
        ))
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")?
            .withSymbolConfiguration(symbolConfig)
        icon.contentTintColor = .secondaryLabelColor
        container.addSubview(icon)
        searchIcon = icon

        searchField = NSSearchField(frame: NSRect(
            x: 44,
            y: top + (searchHeight - 26) / 2,
            width: width - 44 - 16,
            height: 26
        ))
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.font = NSFont.systemFont(ofSize: 20, weight: .regular)
        searchField.textColor = .labelColor
        searchField.drawsBackground = false
        searchField.isBezeled = false
        searchField.isBordered = false
        searchField.placeholderString = isContentSearch ? "Search file contents"
            : (isFileSearch ? "Search files" : (isAppSearch ? "Search apps" : "Search"))
        searchField.autoresizingMask = [.width]

        if let cell = searchField.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }
        container.addSubview(searchField)

        let separator = NSBox(frame: NSRect(x: 0, y: footerHeight + rowHeight * CGFloat(config.numRows), width: width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .minYMargin]
        container.addSubview(separator)
    }

    func listWidth(in container: NSView) -> CGFloat {
        let full = container.bounds.width
        return showsPreview ? full - previewWidth : full
    }

    func setupTable() {
        guard let container = window.contentView else { return }
        let width = listWidth(in: container)
        let tableHeight = rowHeight * CGFloat(config.numRows)

        scrollView = NSScrollView(frame: NSRect(x: 0, y: footerHeight, width: width, height: tableHeight))
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller?.alphaValue = 0
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]

        tableView = ResultTableView(frame: scrollView.bounds)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.target = self
        tableView.action = #selector(handleClick)
        tableView.doubleAction = #selector(handleClick)
        // File search supports dragging results out to Finder (move/copy) or
        // onto an app (open); Finder handles move/copy conflict dialogs.
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ItemColumn"))
        column.width = width
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        container.addSubview(scrollView)
    }

    func setupPreview() {
        guard showsPreview, let container = window.contentView else { return }
        let width = container.bounds.width
        let tableHeight = rowHeight * CGFloat(config.numRows)
        let previewX = width - previewWidth

        let divider = NSBox(frame: NSRect(x: previewX - 1, y: footerHeight, width: 1, height: tableHeight))
        divider.boxType = .separator
        container.addSubview(divider)
        previewDivider = divider

        previewFrame = NSRect(x: previewX, y: footerHeight, width: previewWidth, height: tableHeight)

        // Quick Look for documents, images and folders.
        if let view = QLPreviewView(frame: previewFrame, style: .compact) {
            view.autostarts = false
            view.shouldCloseWithWindow = true
            container.addSubview(view)
            previewView = view
        }

        // Plain-text preview for lyrics / subtitles (Quick Look often cannot
        // render them). Uses a scroll view so long files can be browsed.
        let textScroll = NSScrollView(frame: previewFrame)
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.borderType = .noBorder
        textScroll.drawsBackground = false
        textScroll.isHidden = true
        let textView = NSTextView(frame: textScroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textScroll.documentView = textView
        container.addSubview(textScroll)
        textPreviewScroll = textScroll
        textPreviewView = textView

        // Cover art for audio files (shown above the player controls).
        let art = NSImageView(frame: previewFrame)
        art.imageScaling = .scaleProportionallyUpOrDown
        art.isHidden = true
        container.addSubview(art)
        artworkView = art

        // Title / artist / album caption shown below the artwork.
        let title = NSTextField(labelWithString: "")
        title.alignment = .center
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.isHidden = true
        container.addSubview(title)
        audioTitleLabel = title

        let artist = NSTextField(labelWithString: "")
        artist.alignment = .center
        artist.font = .systemFont(ofSize: 11, weight: .regular)
        artist.textColor = .secondaryLabelColor
        artist.lineBreakMode = .byTruncatingTail
        artist.isHidden = true
        container.addSubview(artist)
        audioArtistLabel = artist

        let album = NSTextField(labelWithString: "")
        album.alignment = .center
        album.font = .systemFont(ofSize: 11, weight: .regular)
        album.textColor = .tertiaryLabelColor
        album.lineBreakMode = .byTruncatingTail
        album.isHidden = true
        container.addSubview(album)
        audioAlbumLabel = album

        // AVPlayer for audio/video so playback can be controlled (Tab).
        let player = AVPlayerView(frame: previewFrame)
        player.controlsStyle = .inline
        player.isHidden = true
        container.addSubview(player)
        playerView = player
    }

    /// Shows/hides the preview pane (and gives the list the full width while
    /// picking a search folder, where no preview is needed).
    func setPreviewPaneVisible(_ visible: Bool) {
        guard showsPreview, let container = window.contentView else { return }
        previewDivider?.isHidden = !visible
        previewView?.isHidden = !visible
        if !visible {
            stopPlayer()
            artworkView?.isHidden = true
            audioTitleLabel?.isHidden = true
            audioArtistLabel?.isHidden = true
            audioAlbumLabel?.isHidden = true
            playerView?.isHidden = true
            textPreviewScroll?.isHidden = true
        }
        let width = visible ? listWidth(in: container) : container.bounds.width
        scrollView.frame.size.width = width
        tableView.frame.size.width = width
        tableView.tableColumns.first?.width = width
    }

    func setupFooter() {
        guard let container = window.contentView else { return }
        let width = container.bounds.width

        let separator = NSBox(frame: NSRect(x: 0, y: footerHeight - 1, width: width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .maxYMargin]
        container.addSubview(separator)

        // Left: action buttons.
        var buttons: [NSButton] = []
        if multiSelectEnabled {
            buttons.append(makeFooterButton("Mark", #selector(footerMark)))
            let clearMarks = makeFooterButton("Clear Marks", #selector(footerClearMarks))
            clearMarksButton = clearMarks
            buttons.append(clearMarks)
        }
        if !isStdin {
            buttons.append(makeFooterButton("Open", #selector(footerOpen)))
            let reveal = makeFooterButton("Reveal in Finder", #selector(footerReveal))
            revealButton = reveal
            buttons.append(reveal)
        }
        buttons.append(makeFooterButton("Return", #selector(footerReturn)))
        updateRevealButton()
        updateClearMarksButton()

        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            stack.heightAnchor.constraint(equalToConstant: 26)
        ])

        // Middle: status text.
        footerLabel = NSTextField(labelWithString: "")
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addSubview(footerLabel)
        NSLayoutConstraint.activate([
            footerLabel.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 12),
            footerLabel.centerYAnchor.constraint(equalTo: stack.centerYAnchor)
        ])

        // Right (file search only): folder picker, plus type filter.
        if isFileSearch {
            let folderButton = NSButton(
                image: NSImage(systemSymbolName: "folder", accessibilityDescription: "Search folder") ?? NSImage(),
                target: self,
                action: #selector(footerChangeFolder)
            )
            folderButton.imagePosition = .imageOnly
            folderButton.bezelStyle = .rounded
            folderButton.controlSize = .small
            folderButton.toolTip = "Change search folder (⌘G)"
            folderButton.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(folderButton)
            NSLayoutConstraint.activate([
                folderButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                folderButton.centerYAnchor.constraint(equalTo: stack.centerYAnchor)
            ])

            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.translatesAutoresizingMaskIntoConstraints = false
            for choice in Self.typeChoices { popup.addItem(withTitle: choice.title) }
            popup.target = self
            popup.action = #selector(typeChanged(_:))
            container.addSubview(popup)
            NSLayoutConstraint.activate([
                popup.trailingAnchor.constraint(equalTo: folderButton.leadingAnchor, constant: -8),
                popup.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
                popup.widthAnchor.constraint(equalToConstant: 130)
            ])
            footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: popup.leadingAnchor, constant: -12).isActive = true
            typePopup = popup

            let current = currentSingleCategory()
            popup.selectItem(at: Self.typeChoices.firstIndex(where: { $0.category == current }) ?? 0)
        } else {
            footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12).isActive = true
        }
    }

    /// Disables "Reveal in Finder" while several items are selected, since a
    /// Finder reveal only makes sense for a single selection.
    func updateRevealButton() {
        revealButton?.isEnabled = !hasMultiSelection
    }

    /// "Clear all marks" is only actionable when something is marked.
    func updateClearMarksButton() {
        clearMarksButton?.isEnabled = multiSelectEnabled && !multiSelection.isEmpty
    }

    func makeFooterButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    func currentSingleCategory() -> FileCategory? {
        guard config.typeFilter.extensions.isEmpty,
              config.typeFilter.categories.count == 1 else { return nil }
        return config.typeFilter.categories.first
    }

    @objc func footerMark() {
        guard !isEditingPath else { return }
        toggleSelection(at: tableView.selectedRow)
    }

    @objc func footerClearMarks() {
        guard !isEditingPath else { return }
        clearAllMarks()
    }

    @objc func footerOpen() {
        guard !isEditingPath else { return }
        config.enterAction = .open
        selectCurrent()
    }

    @objc func footerReveal() {
        guard !isEditingPath else { return }
        guard !hasMultiSelection else { return }
        config.enterAction = .reveal
        selectCurrent()
    }

    /// "Return" button: same as Enter — return the path (or apply --enter).
    @objc func footerReturn() {
        guard !isEditingPath else { return }
        selectCurrent()
    }

    @objc func footerChangeFolder() {
        beginPathEditing()
    }

    @objc func typeChanged(_ sender: NSPopUpButton) {
        let category = Self.typeChoices[sender.indexOfSelectedItem].category
        config.typeFilter = category.map { TypeFilter(extensions: [], categories: [$0]) } ?? TypeFilter()
        allItems.removeAll()
        filteredMatches.removeAll()
        clearSelection()
        tableView.reloadData()
        updateFooter()
        startLoadingData()
    }

    // MARK: - Input loading

    func startLoadingData() {
        let source: ItemSource
        switch config.mode {
        case .stdin:
            source = StdinSource()
        case .files:
            source = FileSource(
                paths: config.searchPaths,
                typeFilter: config.typeFilter,
                namePattern: config.namePattern,
                includeHidden: config.includeHidden
            )
        case .content:
            source = ContentSource(
                paths: config.searchPaths,
                typeFilter: config.typeFilter,
                namePattern: config.namePattern,
                includeHidden: config.includeHidden,
                maxFileSize: config.maxFileSize
            )
        case .apps:
            source = AppSource()
        }

        loadGeneration += 1
        let generation = loadGeneration
        isStreaming = true
        // The incremental content-search state is tied to the item list; reset
        // it and invalidate any in-flight pass so a reload starts clean.
        searchTimer?.invalidate()
        contentMatchTimer?.invalidate()
        contentMatchTimer = nil
        searchGeneration += 1
        pendingContentMatches = 0
        contentSearchActive = false
        contentCandidates = []
        contentCursor = 0
        lastContentQuery = ""
        updateFooter()

        // Re-run the (debounced) content search over the reloaded list.
        if isContentSearch && !searchField.stringValue.isEmpty {
            scheduleContentSearch()
        }

        source.load(
            onBatch: { [weak self] batch in
                guard let self, generation == self.loadGeneration else { return }
                self.appendItems(batch)
            },
            onComplete: { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                self.finishStreaming()
            }
        )
    }

    func appendItems(_ items: [SearchableItem]) {
        allItems.append(contentsOf: items)

        if searchField.stringValue.isEmpty {
            filteredMatches.append(contentsOf: items.map { MatchResult(item: $0, score: 0, termPositions: []) })
            scheduleReload()
        } else if isContentSearch {
            // Always keep new files available as candidates; nothing is matched
            // while typing, so only schedule once the debounced search runs.
            contentCandidates.append(contentsOf: items)
            if contentSearchActive {
                scheduleContentMatch()
            }
        } else {
            scheduleSearch(searchField.stringValue)
        }
        updateFooter()
    }

    func finishStreaming() {
        isStreaming = false
        if isContentSearch {
            if contentSearchActive {
                matchPendingContent()
                finalizeContentSearchIfIdle()
            } else if searchField.stringValue.isEmpty {
                // Plain file list (no query): honour -1 directly.
                autoSelectIfSingle()
            }
        } else {
            applyQuery(searchField.stringValue)
        }
        updateFooter()
    }

    func scheduleReload() {
        reloadTimer?.invalidate()
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.tableView.reloadData()
            if self.tableView.selectedRow < 0 && !self.filteredMatches.isEmpty {
                self.selectRow(0)
            }
        }
    }

    // MARK: - Footer

    func updateFooter() {
        if isEditingPath {
            footerLabel.stringValue = "Choose folder · \(pickerItems.count) folders"
            return
        }

        let total = allItems.count
        let visible = filteredMatches.count

        var text: String
        if isStreaming {
            text = "Searching… \(total) found"
        } else {
            switch config.mode {
            case .files: text = "\(total) files"
            case .content: text = "\(total) files"
            case .apps: text = "\(total) apps"
            case .stdin: text = "\(total) lines"
            }
        }

        if !searchField.stringValue.isEmpty {
            text += " · \(visible) matches"
        }
        if showsPreview {
            text += " · autoplay:\(config.autoplay ? "on" : "off") (⌘↩)"
        }
        footerLabel.stringValue = text
    }

    // MARK: - Table view data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        return displayedItemCount
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return rowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = SpotlightRowView()
        rowView.isMultiSelected = multiSelectEnabled && multiSelection.contains(row)
        return rowView
    }

    // MARK: Drag out (file search only)

    /// Enables dragging a search result out to Finder (move/copy) or onto an
    /// app (open). Only file search rows have a URL, so stdin/app rows and the
    /// folder picker are automatically non-draggable.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard isFileSearch, !isEditingPath else { return nil }
        guard filteredMatches.indices.contains(row) else { return nil }
        guard let url = filteredMatches[row].item.url else { return nil }
        return url as NSURL
    }

    /// When the grabbed row is part of a multi-mark selection, drag every
    /// marked file together so Finder can move/copy them as a group and show
    /// the usual duplicate-name conflict dialog (keep both / replace / stop).
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        isDragging = true
        guard isFileSearch, !isEditingPath, multiSelection.count > 1 else { return }
        guard !rowIndexes.intersection(IndexSet(multiSelection)).isEmpty else { return }

        let urls = multiSelection.sorted().compactMap { itemForRow($0)?.url }
        guard urls.count > 1 else { return }

        let pasteboard = session.draggingPasteboard
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    /// Dragging a result out is a one-shot action: after the drag finishes
    /// there is no returned selection, so exit like Esc. The exit is deferred to
    /// the next runloop turn so AppKit/Finder can finish winding down the drag
    /// session first; terminating synchronously here can leave the destination
    /// window in a broken state (especially for multi-file moves).
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item: SearchableItem
        let match: MatchResult?
        if isEditingPath {
            guard pickerItems.indices.contains(row) else { return nil }
            item = pickerItems[row]
            match = nil
        } else {
            guard filteredMatches.indices.contains(row) else { return nil }
            let result = filteredMatches[row]
            match = result
            item = result.item
        }
        let nameHighlights = match.map { nameHighlightPositions(for: item, match: $0) } ?? []
        let pathHighlights = match.map { pathHighlightPositions(for: item, match: $0) } ?? []

        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("ItemCell")

        let nameField = NSTextField(labelWithString: "")
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.setContentHuggingPriority(NSLayoutConstraint.Priority(251), for: .horizontal)
        nameField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(750), for: .horizontal)
        nameField.attributedStringValue = attributedText(
            item.displayName,
            termHighlights: nameHighlights,
            color: .labelColor,
            font: NSFont.systemFont(ofSize: 14, weight: .regular)
        )
        cell.addSubview(nameField)

        // Row number (1..9) for Cmd+digit quick selection.
        let numberLabel = NSTextField(labelWithString: row < 9 ? "\(row + 1)" : "")
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        numberLabel.textColor = .tertiaryLabelColor
        numberLabel.alignment = .right
        cell.addSubview(numberLabel)

        NSLayoutConstraint.activate([
            numberLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            numberLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            numberLabel.widthAnchor.constraint(equalToConstant: 16)
        ])

        let hasIcon = config.showIcons && item.url != nil

        if hasIcon {
            let iconView = NSImageView()
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.imageScaling = .scaleProportionallyDown
            iconView.image = IconCache.shared.icon(for: item)
            cell.addSubview(iconView)

            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 8),
                iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 20),
                iconView.heightAnchor.constraint(equalToConstant: 20),
                nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8)
            ])
        } else {
            nameField.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 8).isActive = true
        }

        nameField.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true

        if !isAppSearch && !item.parentPath.isEmpty {
            let pathField = NSTextField(labelWithString: "")
            pathField.translatesAutoresizingMaskIntoConstraints = false
            pathField.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            pathField.lineBreakMode = .byTruncatingHead
            pathField.maximumNumberOfLines = 1
            pathField.setContentHuggingPriority(NSLayoutConstraint.Priority(249), for: .horizontal)
            pathField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
            pathField.attributedStringValue = attributedText(
                item.parentPath,
                termHighlights: pathHighlights,
                color: .tertiaryLabelColor,
                font: NSFont.systemFont(ofSize: 11, weight: .regular)
            )
            cell.addSubview(pathField)

            NSLayoutConstraint.activate([
                pathField.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 10),
                pathField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14),
                pathField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        } else {
            nameField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14).isActive = true
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    // MARK: - Focus management

    func focusSearch() {
        window.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() {
            editor.selectedRange = NSRange(location: searchField.stringValue.count, length: 0)
        }
    }

    // MARK: - Search field delegate

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTextField, field === pathField {
            updatePicker()
            return
        }
        applyQueryTags()
        scheduleSearch(searchField.stringValue)
    }
}
