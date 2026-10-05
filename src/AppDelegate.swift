import Cocoa
import Quartz
import AVKit
import AVFoundation

// MARK: - Runtime configuration

struct Config {
    var mode: Mode = .stdin
    var searchPaths: [String] = []
    var typeFilter = TypeFilter()
    var namePattern: String?
    var initialQuery = ""
    var outputNUL = false
    var outputIndex = false
    var autoSelectSingle = false
    var returnQueryOnMismatch = false
    var numRows = 10
    var windowWidth: CGFloat = 720
    var showIcons = true
    var includeHidden = false
    var noPreview = false
    var autoplay = false
    var searchApps = false
    var enterAction: EnterAction = .printPath
    var enterActionExplicit = false

    enum Mode {
        case stdin
        case files
    }

    /// What the Enter key does in file / app search.
    enum EnterAction {
        case printPath
        case open
        case reveal
    }
}

// MARK: - Floating command palette panel

final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Result table view (accepts first responder for native navigation)

final class ResultTableView: NSTableView {
    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Row view with rounded selection highlight (Spotlight style)

final class SpotlightRowView: NSTableRowView {
    private var isHovered = false

    override func drawSelection(in dirtyRect: NSRect) {
        if selectionHighlightStyle != .none {
            let rect = bounds.insetBy(dx: 6, dy: 3)
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            NSColor.controlAccentColor.setFill()
            path.fill()
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isHovered && !isSelected {
            let rect = bounds.insetBy(dx: 6, dy: 3)
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            path.fill()
        }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        return isSelected ? .emphasized : .normal
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
        needsDisplay = true
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource,
                         NSTableViewDelegate, NSSearchFieldDelegate,
                         NSWindowDelegate {

    private var config: Config

    // UI
    private var window: NSPanel!
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var searchField: NSSearchField!
    private var footerLabel: NSTextField!
    private var typePopup: NSPopUpButton?
    private var keyMonitor: Any?
    private var clickMonitor: Any?

    // Data
    private var allItems: [SearchableItem] = []
    private var filteredMatches: [MatchResult] = []
    private var isStreaming = false
    private var loadGeneration = 0
    private var searchGeneration = 0
    private var searchTimer: Timer?
    private var reloadTimer: Timer?

    // Embedded preview: Quick Look for documents/images, AVPlayer for media,
    // plus an artwork view for audio cover art.
    private var previewView: QLPreviewView?
    private var playerView: AVPlayerView?
    private var artworkView: NSImageView?
    private var previewFrame: NSRect = .zero
    /// Custom field editor so query tags get rounded backgrounds.
    private lazy var tagFieldEditor: NSTextView = makeTagFieldEditor()
    private var previewedURL: URL?
    private var artworkToken = 0

    // Layout constants
    private let searchHeight: CGFloat = 56
    private let rowHeight: CGFloat = 40
    private let footerHeight: CGFloat = 44
    private let previewWidth: CGFloat = 360

    /// File types offered by the footer popup (note: no "app" — use --app).
    private static let typeChoices: [(title: String, category: FileCategory?)] = [
        ("All Types", nil),
        ("Images", .image),
        ("Videos", .video),
        ("Audio", .audio),
        ("Documents", .document),
        ("Text", .text),
        ("Archives", .archive),
        ("Folders", .folder)
    ]

    private var showsPreview: Bool {
        // App search is a compact launcher; it does not need a preview pane.
        return config.mode == .files && !config.noPreview && !config.searchApps
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

    func applicationWillTerminate(_ notification: Notification) {
        // nothing to clean up
    }

    /// Invisible menu bar so Cmd+C/X/V/A/Z work inside the search field.
    private func setupMenu() {
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

    private func setupWindow() {
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

    private func setupSearchField() {
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
        searchField.placeholderString = config.mode == .files ? "Search files" : "Search"
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

    private func listWidth(in container: NSView) -> CGFloat {
        let full = container.bounds.width
        return showsPreview ? full - previewWidth : full
    }

    private func setupTable() {
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

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ItemColumn"))
        column.width = width
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        container.addSubview(scrollView)
    }

    private func setupPreview() {
        guard showsPreview, let container = window.contentView else { return }
        let width = container.bounds.width
        let tableHeight = rowHeight * CGFloat(config.numRows)
        let previewX = width - previewWidth

        let divider = NSBox(frame: NSRect(x: previewX - 1, y: footerHeight, width: 1, height: tableHeight))
        divider.boxType = .separator
        container.addSubview(divider)

        previewFrame = NSRect(x: previewX, y: footerHeight, width: previewWidth, height: tableHeight)

        // Quick Look for documents, images and folders.
        if let view = QLPreviewView(frame: previewFrame, style: .compact) {
            view.autostarts = false
            view.shouldCloseWithWindow = true
            container.addSubview(view)
            previewView = view
        }

        // Cover art for audio files (shown above the player controls).
        let art = NSImageView(frame: previewFrame)
        art.imageScaling = .scaleProportionallyUpOrDown
        art.isHidden = true
        container.addSubview(art)
        artworkView = art

        // AVPlayer for audio/video so playback can be controlled (Tab).
        let player = AVPlayerView(frame: previewFrame)
        player.controlsStyle = .inline
        player.isHidden = true
        container.addSubview(player)
        playerView = player
    }

    private func setupFooter() {
        guard let container = window.contentView else { return }
        let width = container.bounds.width

        let separator = NSBox(frame: NSRect(x: 0, y: footerHeight - 1, width: width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .maxYMargin]
        container.addSubview(separator)

        // Left: action buttons.
        var buttons: [NSButton] = []
        if config.mode == .files {
            buttons.append(makeFooterButton("Open", #selector(footerOpen)))
            buttons.append(makeFooterButton("Reveal in Finder", #selector(footerReveal)))
        }
        buttons.append(makeFooterButton("Return", #selector(footerReturn)))

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

        // Right (file search only): type filter.
        if config.mode == .files && !config.searchApps {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.translatesAutoresizingMaskIntoConstraints = false
            for choice in Self.typeChoices { popup.addItem(withTitle: choice.title) }
            popup.target = self
            popup.action = #selector(typeChanged(_:))
            container.addSubview(popup)
            NSLayoutConstraint.activate([
                popup.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
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

    private func makeFooterButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func currentSingleCategory() -> FileCategory? {
        guard config.typeFilter.extensions.isEmpty,
              config.typeFilter.categories.count == 1 else { return nil }
        return config.typeFilter.categories.first
    }

    @objc private func footerOpen() {
        config.enterAction = .open
        selectCurrent()
    }

    @objc private func footerReveal() {
        config.enterAction = .reveal
        selectCurrent()
    }

    /// "Return" button: same as Enter — return the path (or apply --enter).
    @objc private func footerReturn() {
        selectCurrent()
    }

    @objc private func typeChanged(_ sender: NSPopUpButton) {
        let category = Self.typeChoices[sender.indexOfSelectedItem].category
        config.typeFilter = category.map { TypeFilter(extensions: [], categories: [$0]) } ?? TypeFilter()
        allItems.removeAll()
        filteredMatches.removeAll()
        tableView.reloadData()
        updateFooter()
        loadFiles()
    }

    // MARK: - Input loading

    private func startLoadingData() {
        switch config.mode {
        case .stdin:
            loadStdin()
        case .files:
            loadFiles()
        }
    }

    private func loadStdin() {
        if isatty(FileHandle.standardInput.fileDescriptor) != 0 {
            fputs("mff: no input. Pipe items on stdin, or pass a path/type to search files.\n", stderr)
            exit(1)
        }
        isStreaming = true
        updateFooter()

        DispatchQueue.global(qos: .userInitiated).async {
            let handle = FileHandle.standardInput
            let chunkSize = 64 * 1024
            var pending = ""
            var batch: [String] = []
            batch.reserveCapacity(512)

            while true {
                let data = handle.readData(ofLength: chunkSize)
                if data.isEmpty { break }
                var text = pending + (String(data: data, encoding: .utf8) ?? "")
                pending = ""

                while let range = text.range(of: "\n") {
                    let line = String(text[..<range.lowerBound])
                    text = String(text[range.upperBound...])
                    if !line.isEmpty {
                        batch.append(line)
                        if batch.count >= 512 {
                            let chunk = batch
                            batch.removeAll(keepingCapacity: true)
                            let items = chunk.map { SearchableItem(text: $0) }
                            DispatchQueue.main.async { self.appendItems(items) }
                        }
                    }
                }
                pending = text
            }

            if !pending.isEmpty { batch.append(pending) }
            if !batch.isEmpty {
                let chunk = batch
                let items = chunk.map { SearchableItem(text: $0) }
                DispatchQueue.main.async { self.appendItems(items) }
            }

            DispatchQueue.main.async { self.finishStreaming() }
        }
    }

    private func loadFiles() {
        loadGeneration += 1
        let generation = loadGeneration
        isStreaming = true
        updateFooter()

        FileIndexer.enumerate(
            paths: config.searchPaths,
            typeFilter: config.typeFilter,
            namePattern: config.namePattern,
            includeHidden: config.includeHidden,
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

    private func appendItems(_ items: [SearchableItem]) {
        allItems.append(contentsOf: items)

        if searchField.stringValue.isEmpty {
            filteredMatches.append(contentsOf: items.map { MatchResult(item: $0, score: 0, termPositions: []) })
            scheduleReload()
        } else {
            scheduleSearch(searchField.stringValue)
        }
        updateFooter()
    }

    private func finishStreaming() {
        isStreaming = false
        applyQuery(searchField.stringValue)
        updateFooter()
    }

    private func scheduleReload() {
        reloadTimer?.invalidate()
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.tableView.reloadData()
            if self.tableView.selectedRow < 0 && !self.filteredMatches.isEmpty {
                self.selectRow(0)
            }
        }
    }

    // MARK: - Search

    private func scheduleSearch(_ query: String) {
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: false) { [weak self] _ in
            self?.performSearch(query)
        }
    }

    private func applyQuery(_ query: String) {
        searchTimer?.invalidate()
        performSearch(query)
    }

    private func performSearch(_ query: String) {
        let generation = searchGeneration + 1
        searchGeneration = generation
        let items = allItems
        // App search matches only the app name; everything else matches the
        // whole path.
        let matchPath = !config.searchApps

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
                }
                self.updateFooter()

                if self.config.autoSelectSingle && !self.isStreaming && results.count == 1 {
                    self.selectCurrent()
                }
            }
        }
    }

    // MARK: - Footer

    private func updateFooter() {
        let total = allItems.count
        let visible = filteredMatches.count

        var text: String
        if isStreaming {
            text = "Searching… \(total) found"
        } else if config.mode == .files {
            text = "\(total) files"
        } else {
            text = "\(total) lines"
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
        return filteredMatches.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return rowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        return SpotlightRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredMatches.indices.contains(row) else { return nil }
        let match = filteredMatches[row]
        let item = match.item

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
            termHighlights: nameHighlightPositions(for: item, match: match),
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

        if !config.searchApps && !item.parentPath.isEmpty {
            let pathField = NSTextField(labelWithString: "")
            pathField.translatesAutoresizingMaskIntoConstraints = false
            pathField.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            pathField.lineBreakMode = .byTruncatingHead
            pathField.maximumNumberOfLines = 1
            pathField.setContentHuggingPriority(NSLayoutConstraint.Priority(249), for: .horizontal)
            pathField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
            pathField.attributedStringValue = attributedText(
                item.parentPath,
                termHighlights: pathHighlightPositions(for: item, match: match),
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

    // MARK: - Highlighting

    /// One highlight colour per search term, so terms can be told apart.
    private static let termHighlightColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemTeal, .systemBlue, .systemPurple, .systemPink
    ]

    /// Highlight indices (per search term) into the item's file name.
    private func nameHighlightPositions(for item: SearchableItem, match: MatchResult) -> [[Int]] {
        let nameLen = item.displayName.count
        let nameStart = config.searchApps
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
    private func pathHighlightPositions(for item: SearchableItem, match: MatchResult) -> [[Int]] {
        guard !config.searchApps else { return [] }
        let parentLen = item.parentPath.count
        return match.termPositions.map { term in
            term.filter { $0 >= 0 && $0 < parentLen }
        }
    }

    private func attributedText(_ text: String,
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

    // MARK: - Selection

    private func selectRow(_ index: Int) {
        guard filteredMatches.indices.contains(index) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        updatePreview()
    }

    private func moveSelection(_ offset: Int) {
        guard !filteredMatches.isEmpty else { return }
        let current = tableView.selectedRow
        var next = current + offset
        if next < 0 { next = 0 }
        if next >= filteredMatches.count { next = filteredMatches.count - 1 }
        selectRow(next)
    }

    private func moveSelectionByPage(_ direction: Int) {
        moveSelection(direction * max(1, config.numRows))
    }

    private func moveSelectionByHalfPage(_ direction: Int) {
        moveSelection(direction * max(1, config.numRows / 2))
    }

    private func chooseRow(_ index: Int) {
        guard filteredMatches.indices.contains(index) else { return }
        selectRow(index)
        selectCurrent()
    }

    @objc private func handleClick() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard filteredMatches.indices.contains(row) else { return }
        selectRow(row)
        selectCurrent()
    }

    private func currentMatch() -> MatchResult? {
        let row = tableView.selectedRow
        guard filteredMatches.indices.contains(row) else { return nil }
        return filteredMatches[row]
    }

    private func emit(_ item: SearchableItem) {
        if config.outputIndex {
            writeOutput(String(item.id))
        } else {
            writeOutput(item.raw)
        }
    }

    /// Applies the configured Enter behaviour; for `path` it prints the item.
    /// Items without a URL (stdin lines) always print.
    private func performEnter(on item: SearchableItem) {
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

    private func selectCurrent() {
        guard let match = currentMatch() else {
            if config.returnQueryOnMismatch {
                writeOutput(searchField.stringValue)
                exit(0)
            }
            exit(1)
        }
        performEnter(on: match.item)
        exit(0)
    }

    /// Cmd+O: open the selected file with its default application.
    private func openSelectedFile() {
        guard let match = currentMatch(), let url = match.item.url else { return }
        NSWorkspace.shared.open(url)
        exit(0)
    }

    /// Cmd+T: open the file-type popup so it can be changed from the keyboard.
    private func openTypePopup() {
        typePopup?.performClick(nil)
    }

    /// Cmd+R: reveal the selected file in Finder.
    private func revealSelectedFile() {
        guard let match = currentMatch(), let url = match.item.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        exit(0)
    }

    private func cancel() {
        if config.returnQueryOnMismatch {
            writeOutput(searchField.stringValue)
            exit(0)
        }
        exit(1)
    }

    private func writeOutput(_ string: String) {
        var output = string
        output += config.outputNUL ? "\u{0}" : "\n"
        FileHandle.standardOutput.write(Data(output.utf8))
        fflush(stdout)
    }

    // MARK: - Focus management

    private func focusSearch() {
        window.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() {
            editor.selectedRange = NSRange(location: searchField.stringValue.count, length: 0)
        }
    }

    // MARK: - Quick Look preview (embedded)

    private func selectedItem() -> SearchableItem? {
        let row = tableView.selectedRow
        guard filteredMatches.indices.contains(row) else { return nil }
        return filteredMatches[row].item
    }

    private func updatePreview() {
        guard showsPreview, let previewView, let playerView else { return }

        guard let item = selectedItem(), let url = item.url else {
            previewedURL = nil
            stopPlayer()
            artworkView?.isHidden = true
            previewView.isHidden = false
            previewView.previewItem = nil
            return
        }

        // Skip redundant updates (selectRow + selection-did-change both call
        // us) so media playback is not restarted.
        if url == previewedURL { return }
        previewedURL = url

        if isVideo(item) {
            artworkView?.isHidden = true
            previewView.previewItem = nil
            previewView.isHidden = true
            stopPlayer()
            playerView.frame = previewFrame
            playerView.isHidden = false
            loadMediaPlayer(url: url)
        } else if isAudio(item) {
            previewView.previewItem = nil
            previewView.isHidden = true
            stopPlayer()
            layoutAudioPreview()
            playerView.isHidden = false
            loadMediaPlayer(url: url)
            loadArtwork(for: url)
        } else {
            // Everything else: Finder-style Quick Look.
            stopPlayer()
            artworkView?.isHidden = true
            previewView.isHidden = false
            previewView.previewItem = url as NSURL
        }
    }

    private func loadMediaPlayer(url: URL) {
        let player = AVPlayer(url: url)
        playerView?.player = player
        if config.autoplay { player.play() }
    }

    /// Audio layout: cover art on top, a compact player controls strip below.
    private func layoutAudioPreview() {
        let controlsHeight: CGFloat = 64
        artworkView?.isHidden = false
        artworkView?.frame = NSRect(
            x: previewFrame.minX,
            y: previewFrame.minY + controlsHeight,
            width: previewFrame.width,
            height: previewFrame.height - controlsHeight
        )
        playerView?.frame = NSRect(
            x: previewFrame.minX,
            y: previewFrame.minY,
            width: previewFrame.width,
            height: controlsHeight
        )
    }

    private func loadArtwork(for url: URL) {
        artworkToken += 1
        let token = artworkToken

        // Show a music note while the (async) artwork is being extracted.
        artworkView?.contentTintColor = .tertiaryLabelColor
        artworkView?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 72, weight: .regular))

        DispatchQueue.global(qos: .userInitiated).async {
            let image = Self.artworkImage(for: url)
            DispatchQueue.main.async {
                guard token == self.artworkToken else { return }
                if let image {
                    self.artworkView?.contentTintColor = nil
                    self.artworkView?.image = image
                }
            }
        }
    }

    /// Extracts the embedded cover art (album artwork) from an audio file.
    private static func artworkImage(for url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        for item in asset.commonMetadata {
            guard item.commonKey == .commonKeyArtwork else { continue }
            if let data = item.value as? Data, let image = NSImage(data: data) {
                return image
            }
            if let data = item.dataValue, let image = NSImage(data: data) {
                return image
            }
        }
        return nil
    }

    private func stopPlayer() {
        playerView?.player?.pause()
        playerView?.player = nil
        playerView?.isHidden = true
    }

    private func isAudio(_ item: SearchableItem) -> Bool {
        guard !item.isDirectory, let url = item.url else { return false }
        return FileTypeRegistry.audioExts.contains(url.pathExtension.lowercased())
    }

    private func isVideo(_ item: SearchableItem) -> Bool {
        guard !item.isDirectory, let url = item.url else { return false }
        return FileTypeRegistry.videoExts.contains(url.pathExtension.lowercased())
    }

    /// Cmd+Return: toggle whether audio/video auto-plays. The current item
    /// follows immediately (starts when turning on, pauses when turning off).
    private func toggleAutoplay() {
        config.autoplay.toggle()
        if let playerView, !playerView.isHidden, let player = playerView.player {
            if config.autoplay {
                player.play()
            } else {
                player.pause()
            }
        }
        updateFooter()
    }

    /// Renders each Tab-separated term in the query field as its own coloured
    /// rounded "tag" so the terms are easy to tell apart while typing.
    private func applyQueryTags() {
        guard let editor = searchField.currentEditor() as? NSTextView,
              let storage = editor.textStorage,
              !editor.hasMarkedText() else { return }

        let string = storage.string
        let full = NSRange(location: 0, length: (string as NSString).length)
        storage.beginEditing()
        storage.removeAttribute(.mffTagBackground, range: full)
        storage.removeAttribute(.underlineStyle, range: full)
        storage.addAttribute(.foregroundColor,
                             value: searchField.textColor ?? NSColor.labelColor,
                             range: full)

        for (termIndex, range) in queryTermRanges(in: string).enumerated() {
            let color = Self.termHighlightColors[termIndex % Self.termHighlightColors.count]
                .withAlphaComponent(0.35)
            storage.addAttribute(.mffTagBackground, value: color, range: NSRange(range, in: string))
        }
        storage.endEditing()

        // Keep newly typed characters from inheriting a tag background.
        editor.typingAttributes = [
            .font: searchField.font ?? NSFont.systemFont(ofSize: 20),
            .foregroundColor: NSColor.labelColor
        ]
    }

    /// Ranges of the Tab-separated terms in `string`.
    private func queryTermRanges(in string: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = string.startIndex
        var i = string.startIndex
        while i < string.endIndex {
            let c = string[i]
            if c == "\t" || c == FuzzyMatcher.termSeparator {
                if start < i { ranges.append(start..<i) }
                i = string.index(after: i)
                start = i
                continue
            }
            i = string.index(after: i)
        }
        if start < string.endIndex { ranges.append(start..<string.endIndex) }
        return ranges
    }

    /// Tab inserts a term separator into the query (terms are Tab-separated).
    private func insertQuerySeparator() {
        window.makeFirstResponder(searchField)
        searchField.stringValue.append(FuzzyMatcher.termSeparator)
        if let editor = searchField.currentEditor() {
            editor.selectedRange = NSRange(location: (searchField.stringValue as NSString).length, length: 0)
        }
        applyQueryTags()
        scheduleSearch(searchField.stringValue)
    }

    // MARK: - Keyboard handling

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let key = event.keyCode
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Global Command shortcuts (work regardless of focus).
            let isCmd = mods.contains(.command)
                && !mods.contains(.control)
                && !mods.contains(.option)
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
                case 126: self.moveSelection(-1); return nil
                case 125: self.moveSelection(1); return nil
                case 116: self.moveSelectionByPage(-1); return nil // page up
                case 121: self.moveSelectionByPage(1); return nil  // page down
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
                        if key == 35 || key == 40 { self.moveSelection(-1); return nil }
                        if key == 45 || key == 38 { self.moveSelection(1); return nil }
                        if key == 32 { self.moveSelectionByHalfPage(-1); return nil } // ctrl+u
                        if key == 2 { self.moveSelectionByHalfPage(1); return nil }   // ctrl+d
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
                case 123, 124, 125, 126, 117:
                    return event // arrows / forward-delete handled natively by the table
                case 116: self.moveSelectionByPage(-1); return nil // page up
                case 121: self.moveSelectionByPage(1); return nil  // page down
                case 115: self.selectRow(0); return nil            // home
                case 119: self.selectRow(self.filteredMatches.count - 1); return nil // end
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

    private func isPrintable(_ event: NSEvent) -> Bool {
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

    private func installClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            let point = NSEvent.mouseLocation
            if self.window.frame.contains(point) { return }
            NSApp.terminate(nil)
        }
    }

    private func installFocusObserver() {
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
        NSApp.terminate(nil)
    }

    // MARK: - Search field delegate

    func controlTextDidChange(_ obj: Notification) {
        applyQueryTags()
        scheduleSearch(searchField.stringValue)
    }
}
