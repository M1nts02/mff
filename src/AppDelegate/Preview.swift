import Cocoa
import Quartz
import AVKit
import AVFoundation

extension AppDelegate {

    // MARK: - Quick Look preview (embedded)

    func selectedItem() -> SearchableItem? {
        let row = tableView.selectedRow
        if isEditingPath {
            return pickerItems.indices.contains(row) ? pickerItems[row] : nil
        }
        guard filteredMatches.indices.contains(row) else { return nil }
        return filteredMatches[row].item
    }

    func updatePreview() {
        guard showsPreview, !isEditingPath, let previewView, let playerView else { return }

        guard let item = selectedItem(), let url = item.url else {
            previewedURL = nil
            stopPlayer()
            artworkView?.isHidden = true
            audioTitleLabel?.isHidden = true
            audioArtistLabel?.isHidden = true
            audioAlbumLabel?.isHidden = true
            textPreviewScroll?.isHidden = true
            previewView.isHidden = false
            previewView.previewItem = nil
            return
        }

        // Skip redundant updates (selectRow + selection-did-change both call
        // us) so media playback is not restarted.
        if url == previewedURL { return }
        previewedURL = url

        if isVideo(item) {
            textPreviewScroll?.isHidden = true
            previewView.previewItem = nil
            previewView.isHidden = true
            stopPlayer()
            if isMatroskaVideo(item) {
                // AVFoundation cannot decode Matroska, so show the embedded
                // cover (or a film placeholder) instead of a blank player.
                loadVideoCover(for: url)
            } else {
                artworkView?.isHidden = true
                audioTitleLabel?.isHidden = true
                audioArtistLabel?.isHidden = true
                audioAlbumLabel?.isHidden = true
                playerView.frame = previewFrame
                playerView.isHidden = false
                loadMediaPlayer(url: url)
            }
        } else if isAudio(item) {
            textPreviewScroll?.isHidden = true
            previewView.previewItem = nil
            previewView.isHidden = true
            stopPlayer()
            layoutAudioPreview()
            playerView.isHidden = false
            loadMediaPlayer(url: url)
            loadArtwork(for: item)
        } else if isLyricsOrSubtitle(item) {
            // Show the file as plain text so lyrics / subtitles are browseable
            // even without a Quick Look generator.
            stopPlayer()
            artworkView?.isHidden = true
            audioTitleLabel?.isHidden = true
            audioArtistLabel?.isHidden = true
            audioAlbumLabel?.isHidden = true
            previewView.previewItem = nil
            previewView.isHidden = true
            showTextPreview(for: url)
        } else {
            // Everything else: Finder-style Quick Look.
            stopPlayer()
            artworkView?.isHidden = true
            audioTitleLabel?.isHidden = true
            audioArtistLabel?.isHidden = true
            audioAlbumLabel?.isHidden = true
            textPreviewScroll?.isHidden = true
            previewView.isHidden = false
            previewView.previewItem = url as NSURL
        }
    }

    /// Lyrics / subtitle formats, previewed as plain text.
    func isLyricsOrSubtitle(_ item: SearchableItem) -> Bool {
        guard !item.isDirectory, let url = item.url else { return false }
        return FileTypeRegistry.lyricsSubtitleExts.contains(url.pathExtension.lowercased())
    }

    /// Fills the plain-text preview with a lyrics / subtitle file.
    func showTextPreview(for url: URL) {
        guard let textPreviewScroll, let textPreviewView else { return }
        textPreviewScroll.frame = previewFrame
        textPreviewScroll.isHidden = false
        textPreviewView.string = Self.readTextFile(url)
        textPreviewView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    /// Reads a small text file, tolerating non-UTF-8 encodings and flagging
    /// binary files (e.g. VobSub `.sub`) instead of dumping garbage.
    static func readTextFile(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "(unable to read file)" }
        if data.prefix(8000).contains(0) { return "(binary file — no text preview)" }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    func loadMediaPlayer(url: URL) {
        let player = AVPlayer(url: url)
        playerView?.player = player
        if config.autoplay { player.play() }
    }

    /// Audio layout: cover art on top, title/artist/album below it, and a
    /// compact player controls strip at the bottom.
    func layoutAudioPreview() {
        let controlsHeight: CGFloat = 64
        let captionHeight: CGFloat = 58
        artworkView?.isHidden = false
        artworkView?.frame = NSRect(
            x: previewFrame.minX,
            y: previewFrame.minY + controlsHeight + captionHeight,
            width: previewFrame.width,
            height: previewFrame.height - controlsHeight - captionHeight
        )

        audioTitleLabel?.isHidden = false
        audioTitleLabel?.frame = NSRect(
            x: previewFrame.minX + 10,
            y: previewFrame.minY + controlsHeight + 39,
            width: previewFrame.width - 20,
            height: 18
        )
        audioArtistLabel?.isHidden = false
        audioArtistLabel?.frame = NSRect(
            x: previewFrame.minX + 10,
            y: previewFrame.minY + controlsHeight + 21,
            width: previewFrame.width - 20,
            height: 16
        )
        audioAlbumLabel?.isHidden = false
        audioAlbumLabel?.frame = NSRect(
            x: previewFrame.minX + 10,
            y: previewFrame.minY + controlsHeight + 3,
            width: previewFrame.width - 20,
            height: 16
        )

        playerView?.frame = NSRect(
            x: previewFrame.minX,
            y: previewFrame.minY,
            width: previewFrame.width,
            height: controlsHeight
        )
    }

    /// Matroska cover preview: an embedded image, or a film placeholder while
    /// it is being read / when the file has none.
    func loadVideoCover(for url: URL) {
        artworkToken += 1
        let token = artworkToken

        artworkView?.contentTintColor = .tertiaryLabelColor
        artworkView?.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 64, weight: .regular))
        layoutVideoCoverPreview()
        audioTitleLabel?.stringValue = url.lastPathComponent

        DispatchQueue.global(qos: .userInitiated).async {
            let cover = MatroskaCover.read(url)
            DispatchQueue.main.async {
                guard token == self.artworkToken else { return }
                if let cover, let image = NSImage(data: cover) {
                    self.artworkView?.contentTintColor = nil
                    self.artworkView?.image = image
                }
            }
        }
    }

    /// Cover layout: the image fills the pane with the file name below it.
    func layoutVideoCoverPreview() {
        let captionHeight: CGFloat = 40
        artworkView?.isHidden = false
        artworkView?.frame = NSRect(
            x: previewFrame.minX,
            y: previewFrame.minY + captionHeight,
            width: previewFrame.width,
            height: previewFrame.height - captionHeight
        )
        audioTitleLabel?.isHidden = false
        audioTitleLabel?.frame = NSRect(
            x: previewFrame.minX + 10,
            y: previewFrame.minY + 12,
            width: previewFrame.width - 20,
            height: 18
        )
        audioArtistLabel?.isHidden = true
        audioAlbumLabel?.isHidden = true
    }

    func loadArtwork(for item: SearchableItem) {
        guard let url = item.url else { return }
        artworkToken += 1
        let token = artworkToken

        audioMetadata = nil
        // Show a music note while the (async) metadata is being extracted.
        artworkView?.contentTintColor = .tertiaryLabelColor
        artworkView?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 72, weight: .regular))
        audioTitleLabel?.stringValue = url.deletingPathExtension().lastPathComponent
        audioArtistLabel?.stringValue = ""
        audioAlbumLabel?.stringValue = ""

        DispatchQueue.global(qos: .userInitiated).async {
            let metadata = Self.embeddedMetadata(for: url)
            let image = metadata.artwork.flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                guard token == self.artworkToken else { return }
                if let image {
                    self.artworkView?.contentTintColor = nil
                    self.artworkView?.image = image
                }
                self.audioMetadata = metadata
                self.renderAudioMetadata()
            }
        }
    }

    /// Draws the audio title / artist / album with the search hits highlighted.
    /// Terms that already matched the file path are not highlighted: their
    /// contents were never searched.
    func renderAudioMetadata() {
        guard let item = selectedItem(), isAudio(item), let metadata = audioMetadata else { return }
        let title = metadata.title ?? item.url?.deletingPathExtension().lastPathComponent ?? ""
        let artist = metadata.artist ?? ""
        let album = metadata.album ?? ""

        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let lineFont = NSFont.systemFont(ofSize: 11, weight: .regular)

        audioTitleLabel?.attributedStringValue = attributedText(
            title,
            termHighlights: metadataHighlights(title, item: item),
            color: .labelColor,
            font: titleFont
        )
        audioArtistLabel?.attributedStringValue = attributedText(
            artist,
            termHighlights: metadataHighlights(artist, item: item),
            color: .secondaryLabelColor,
            font: lineFont
        )
        audioAlbumLabel?.attributedStringValue = attributedText(
            album,
            termHighlights: metadataHighlights(album, item: item),
            color: .tertiaryLabelColor,
            font: lineFont
        )
    }

    /// Per-term highlight positions for one metadata field, aligned to the query
    /// terms so the colours match the query tags.
    func metadataHighlights(_ text: String, item: SearchableItem) -> [[Int]] {
        let haystack = Array(text.lowercased())
        return FuzzyMatcher.tokenize(searchField.stringValue).map { token in
            var body = token
            var negate = false
            if body.hasPrefix("!") {
                negate = true
                body.removeFirst()
            }
            if negate || body.isEmpty { return [] }
            // A term that matched the path takes priority; its contents were
            // never searched, so leave the metadata unhighlighted.
            if FuzzyMatcher.match(query: token, in: item, matchPath: true) != nil { return [] }
            let needle = Array((body.hasPrefix("'") ? String(body.dropFirst()) : body).lowercased())
            guard !needle.isEmpty else { return [] }
            return Self.substringPositions(needle, in: haystack)
        }
    }

    static func substringPositions(_ needle: [Character], in haystack: [Character]) -> [Int] {
        let m = needle.count, n = haystack.count
        guard m > 0, m <= n else { return [] }
        for i in 0...(n - m) {
            var found = true
            for j in 0..<m where haystack[i + j] != needle[j] {
                found = false
                break
            }
            if found { return Array(i..<(i + m)) }
        }
        return []
    }

    /// Tag / artwork metadata for an audio file. FLAC and Ogg are parsed by us
    /// because AVFoundation cannot read their comments; everything else falls
    /// back to the common metadata AVFoundation does expose.
    static func embeddedMetadata(for url: URL) -> AudioMetadata {
        if let parsed = AudioMetadata.read(url), !parsed.isEmpty {
            return parsed
        }

        var metadata = AudioMetadata()
        for item in AVURLAsset(url: url).commonMetadata {
            switch item.commonKey {
            case .commonKeyTitle:
                metadata.title = metadata.title ?? item.stringValue
            case .commonKeyArtist:
                metadata.artist = metadata.artist ?? item.stringValue
            case .commonKeyAlbumName:
                metadata.album = metadata.album ?? item.stringValue
            case .commonKeyArtwork:
                if metadata.artwork == nil {
                    metadata.artwork = item.dataValue ?? item.value as? Data
                }
            default:
                break
            }
        }
        return metadata
    }

    func stopPlayer() {
        playerView?.player?.pause()
        playerView?.player = nil
        playerView?.isHidden = true
    }

    func isAudio(_ item: SearchableItem) -> Bool {
        guard !item.isDirectory, let url = item.url else { return false }
        return FileTypeRegistry.audioExts.contains(url.pathExtension.lowercased())
    }

    func isVideo(_ item: SearchableItem) -> Bool {
        guard !item.isDirectory, let url = item.url else { return false }
        return FileTypeRegistry.videoExts.contains(url.pathExtension.lowercased())
    }

    /// Matroska / WebM containers, whose cover image (if any) we read ourselves.
    func isMatroskaVideo(_ item: SearchableItem) -> Bool {
        guard !item.isDirectory, let url = item.url else { return false }
        return ["mkv", "webm"].contains(url.pathExtension.lowercased())
    }

    /// Cmd+Return: toggle whether audio/video auto-plays. The current item
    /// follows immediately (starts when turning on, pauses when turning off).
    func toggleAutoplay() {
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
    func applyQueryTags() {
        // Keep the audio metadata highlights in sync with the query.
        defer { renderAudioMetadata() }
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
    func queryTermRanges(in string: String) -> [Range<String.Index>] {
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
    func insertQuerySeparator() {
        window.makeFirstResponder(searchField)
        searchField.stringValue.append(FuzzyMatcher.termSeparator)
        if let editor = searchField.currentEditor() {
            editor.selectedRange = NSRange(location: (searchField.stringValue as NSString).length, length: 0)
        }
        applyQueryTags()
        scheduleSearch(searchField.stringValue)
    }
}
