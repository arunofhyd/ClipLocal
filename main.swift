import Cocoa
import CryptoKit
import ServiceManagement

// ============================================================
//  ClipLocal — 100% on-device clipboard history, no third parties
// ============================================================

let appVersion = "1.8"
let updateCheckURL = "https://raw.githubusercontent.com/arunofhyd/ClipLocal/main/version.json"
let downloadPageURL = "https://cliplocal.vercel.app/#install"

// MARK: - Custom UI Components

/// Ensures the NSSearchField reliably grabs focus and shows the blinking cursor inside an NSMenu.
class MenuSearchField: NSSearchField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            // Attempt to grab focus immediately when added to the window
            self.window?.makeFirstResponder(self)

            // Dispatch asynchronously to guarantee it catches the cursor blink
            // after the menu has fully transitioned onto the screen.
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let win = self.window else { return }
                win.makeFirstResponder(self)
                self.currentEditor()?.moveToEndOfLine(nil)
            }
        }
    }
}

/// Provides a smooth, animated background highlight when selecting filters.
class FilterButton: NSButton {
    var hasItems: Bool = false {
        didSet { updateVisuals(animated: false) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        setButtonType(.toggle)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 5
        imageScaling = .scaleProportionallyDown
        // Crucial: Prevents the button from stealing focus from the search bar when clicked
        refusesFirstResponder = true
    }

    func setSelected(_ selected: Bool, animated: Bool = true) {
        self.state = selected ? .on : .off
        updateVisuals(animated: animated)
    }

    private func updateVisuals(animated: Bool) {
        let selected = self.state == .on
        let updateUI = {
            self.layer?.borderWidth = 0

            if selected {
                self.contentTintColor = .white
                self.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                self.animator().alphaValue = 1.0
            } else {
                self.layer?.backgroundColor = NSColor.clear.cgColor

                if self.hasItems {
                    self.contentTintColor = .labelColor
                    self.animator().alphaValue = 1.0
                } else {
                    self.contentTintColor = .tertiaryLabelColor
                    self.animator().alphaValue = 0.2
                }
            }
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.allowsImplicitAnimation = true
                updateUI()
            }
        } else {
            updateUI()
        }
    }
}

// MARK: - Encryption key (stored in a protected local file)
enum KeyStore {
    static var keyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipLocal")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("key.bin")
    }

    static func loadOrCreateKey() -> SymmetricKey {
        if let data = try? Data(contentsOf: keyURL), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try? data.write(to: keyURL, options: .completeFileProtection)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: keyURL.path)
        return key
    }

    static func deleteKey() { try? FileManager.default.removeItem(at: keyURL) }
}

// MARK: - A single clipboard entry
struct ClipItem: Codable {
    let text: String
    let date: Date
    var pinned: Bool = false
    var imageData: Data?
}

enum PrivacyMode: String {
    case session
    case persistent
}

// MARK: - The app
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSSearchFieldDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var lastChangeCount = NSPasteboard.general.changeCount
    var history: [ClipItem] = []
    let key = KeyStore.loadOrCreateKey()
    let defaults = UserDefaults.standard
    var previewWindow: NSWindow?

    var isMenuOpen = false
    var currentSearchText = ""
    var activeFilters: Set<String> = []
    var historyMenuItems: [NSMenuItem] = []
    var searchField: NSSearchField?
    var needsRebuildAfterClose = false
    var filtersMenuItem: NSMenuItem?
    var focusTimer: Timer?

    var mode: PrivacyMode {
        get { PrivacyMode(rawValue: defaults.string(forKey: "mode") ?? "persistent") ?? .persistent }
        set { defaults.set(newValue.rawValue, forKey: "mode"); persistIfNeeded(); rebuildMenu() }
    }
    var skipConcealed: Bool {
        get { defaults.object(forKey: "skipConcealed") == nil ? true : defaults.bool(forKey: "skipConcealed") }
        set { defaults.set(newValue, forKey: "skipConcealed"); rebuildMenu() }
    }
    var showImageDimensions: Bool {
        get { defaults.bool(forKey: "showImageDimensions") }
        set { defaults.set(newValue, forKey: "showImageDimensions"); rebuildMenu() }
    }
    var showFullFilePath: Bool {
        get { defaults.bool(forKey: "showFullFilePath") }
        set { defaults.set(newValue, forKey: "showFullFilePath"); rebuildMenu() }
    }
    var maxItems: Int {
        get { let v = defaults.integer(forKey: "maxItems"); return v == 0 ? 50 : v }
        set { defaults.set(newValue, forKey: "maxItems"); rebuildMenu() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if defaults.object(forKey: "hasLaunchedBefore") == nil {
            defaults.set(true, forKey: "hasLaunchedBefore")
            try? SMAppService.mainApp.register()
        }

        NSApp.setActivationPolicy(.accessory) // menu-bar only, no dock icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                   accessibilityDescription: "ClipLocal")
        }
        if mode == .persistent { loadHistory() }
        rebuildMenu()
        showAbout(onLaunch: true)
        checkForUpdates(silentIfCurrent: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    // MARK: - About window (privacy-first splash)
    var aboutWindow: NSWindow?

    @objc func showAboutMenu() { showAbout(onLaunch: false) }

    func showAbout(onLaunch: Bool) {
        if onLaunch && defaults.bool(forKey: "hideAbout") { return }

        aboutWindow?.close()
        let width: CGFloat = 460, height: CGFloat = 700
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "ClipLocal"
        win.isReleasedWhenClosed = false
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.center()
        win.level = .floating

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bg.material = .underWindowBackground
        bg.state = .active
        bg.wantsLayer = true

        let icon = NSImageView(frame: NSRect(x: (width - 72)/2, y: height - 120, width: 72, height: 72))
        let cfg = NSImage.SymbolConfiguration(pointSize: 60, weight: .regular)
        icon.image = NSImage(systemSymbolName: "lock.doc.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        icon.contentTintColor = NSColor.controlAccentColor
        bg.addSubview(icon)

        let name = NSTextField(labelWithString: "ClipLocal")
        name.frame = NSRect(x: 0, y: height - 164, width: width, height: 32)
        name.alignment = .center
        name.font = NSFont.systemFont(ofSize: 26, weight: .bold)
        bg.addSubview(name)

        let version = NSTextField(labelWithString: "Version \(appVersion)")
        version.frame = NSRect(x: 0, y: height - 186, width: width, height: 16)
        version.alignment = .center
        version.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        version.textColor = .tertiaryLabelColor
        bg.addSubview(version)

        let tagline = NSTextField(labelWithString: "Your clipboard. Yours alone.")
        tagline.frame = NSRect(x: 0, y: height - 210, width: width, height: 18)
        tagline.alignment = .center
        tagline.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        tagline.textColor = .secondaryLabelColor
        bg.addSubview(tagline)

        let bodyText = """
        🔒  100% on-device. Your clipboard data NEVER leaves your Mac — no cloud, no servers, no accounts, no analytics, no third parties. Ever.

        💾  In Persistent mode, history is encrypted with a key stored in a protected file that only your macOS account can read.

        🔑  Session-only mode keeps everything in memory and wipes it the moment you quit.

        🛡️  Copies from password managers are skipped by default, and you can clear everything instantly anytime.

        ⌘  Open the menu and press ⌘1–⌘9 to instantly copy any of your recent items.

        🏷️  Each item shows a relevant icon — 🔗 links, ✉️ emails, #️⃣ numbers, 🧑‍💻 code, 📄 files, and 🖼️ images — so your history is easy to scan.
        """
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        let attr = NSAttributedString(string: bodyText, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ])
        let bodyWidth = width - 80
        let measured = attr.boundingRect(
            with: NSSize(width: bodyWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let textHeight = ceil(measured.height) + 8
        let privacy = NSTextField(labelWithAttributedString: attr)
        privacy.lineBreakMode = .byWordWrapping
        privacy.maximumNumberOfLines = 0
        privacy.preferredMaxLayoutWidth = bodyWidth
        let textTop = (height - 210) - 24

        let bottomSpaceNeeded: CGFloat = 160
        let newHeight = (height - textTop) + textHeight + bottomSpaceNeeded
        let finalHeight = max(height, newHeight)

        let oldFrame = win.frame
        win.setFrame(NSRect(x: oldFrame.minX, y: oldFrame.maxY - finalHeight, width: width, height: finalHeight), display: true)
        bg.frame = NSRect(x: 0, y: 0, width: width, height: finalHeight)

        icon.frame.origin.y = finalHeight - 120
        name.frame.origin.y = finalHeight - 164
        version.frame.origin.y = finalHeight - 186
        tagline.frame.origin.y = finalHeight - 210
        let newTextTop = (finalHeight - 210) - 24

        privacy.frame = NSRect(x: 40, y: newTextTop - textHeight, width: bodyWidth, height: textHeight)
        bg.addSubview(privacy)

        let credit = NSTextField(labelWithString: "Built by Arun Thomas")
        credit.frame = NSRect(x: 0, y: (newTextTop - textHeight) - 34, width: width, height: 18)
        credit.alignment = .center
        credit.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        credit.textColor = .secondaryLabelColor
        bg.addSubview(credit)

        let dontShow = NSButton(checkboxWithTitle: "Don't show again",
                                target: self, action: #selector(toggleHideAbout(_:)))
        dontShow.font = NSFont.systemFont(ofSize: 11)
        dontShow.sizeToFit()
        let dsW = dontShow.frame.width
        let dontShowY = credit.frame.minY - 40
        dontShow.frame = NSRect(x: (width - dsW)/2, y: dontShowY, width: dsW, height: 20)
        dontShow.state = defaults.bool(forKey: "hideAbout") ? .on : .off
        bg.addSubview(dontShow)

        let contact = NSButton(title: "Contact", target: self, action: #selector(contactDeveloper))
        let buttonsY = dontShow.frame.minY - 48
        contact.frame = NSRect(x: 40, y: buttonsY, width: 100, height: 32)
        contact.bezelStyle = .rounded
        bg.addSubview(contact)

        let close = NSButton(title: "Get Started", target: self, action: #selector(closeAbout))
        close.frame = NSRect(x: width - 160, y: buttonsY, width: 120, height: 32)
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        close.bezelColor = NSColor.controlAccentColor
        close.attributedTitle = NSAttributedString(string: "Get Started", attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ])
        bg.addSubview(close)

        win.contentView = bg
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow = win
    }

    @objc func contactDeveloper() {
        let subject = "ClipLocal feedback"
        let encoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        if let url = URL(string: "mailto:arunthomas04042001@gmail.com?subject=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func toggleHideAbout(_ sender: NSButton) {
        defaults.set(sender.state == .on, forKey: "hideAbout")
    }

    @objc func closeAbout() { aboutWindow?.close(); aboutWindow = nil }

    // MARK: - Watching the clipboard
    func checkClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        if skipConcealed {
            let types = pb.types ?? []
            let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
            let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
            if types.contains(concealed) || types.contains(transient) { return }
        }

        var textToStore = ""
        var imageToStore: Data? = nil

        if let fileURLs = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let firstURL = fileURLs.first, firstURL.isFileURL {
            textToStore = firstURL.path
        } else if let img = NSImage(pasteboard: pb),
           let tiff = img.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            imageToStore = pngData
            textToStore = "[Image: \(Int(img.size.width))x\(Int(img.size.height))]"
        } else if let text = pb.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textToStore = text
        } else {
            return
        }

        var pinned = false
        if let idx = history.firstIndex(where: {
            if let img1 = $0.imageData, let img2 = imageToStore {
                return img1 == img2
            }
            return $0.imageData == nil && imageToStore == nil && $0.text == textToStore
        }) {
            pinned = history[idx].pinned
            history.remove(at: idx)
        }
        history.insert(ClipItem(text: textToStore, date: Date(), pinned: pinned, imageData: imageToStore), at: 0)
        trimHistory()
        persistIfNeeded()
        rebuildMenu()
        showPreview(textToStore)
    }

    func trimHistory() {
        var nonPinned = 0
        var result: [ClipItem] = []
        for item in history {
            if item.pinned { result.append(item) }
            else if nonPinned < maxItems { result.append(item); nonPinned += 1 }
        }
        history = result
    }

    // MARK: - Bottom-right "Copied" preview
    func showPreview(_ text: String) {
        previewWindow?.close()
        let snippet = String(text.prefix(90)).replacingOccurrences(of: "\n", with: " ")
        let width: CGFloat = 320, height: CGFloat = 66
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.maxX - width - 20
        let y = frame.minY + 20

        let win = NSWindow(contentRect: NSRect(x: x, y: y, width: width, height: height),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.isReleasedWhenClosed = false
        win.backgroundColor = .clear
        win.level = .floating
        win.ignoresMouseEvents = true
        win.hasShadow = true

        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "✓ Copied")
        title.frame = NSRect(x: 14, y: height - 26, width: width - 28, height: 18)
        title.font = NSFont.boldSystemFont(ofSize: 12)
        title.textColor = .secondaryLabelColor

        let body = NSTextField(labelWithString: snippet)
        body.frame = NSRect(x: 14, y: 8, width: width - 28, height: 30)
        body.font = NSFont.systemFont(ofSize: 13)
        body.lineBreakMode = .byTruncatingTail
        body.maximumNumberOfLines = 2

        container.addSubview(title)
        container.addSubview(body)
        win.contentView = container
        win.alphaValue = 0
        win.orderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            win.animator().alphaValue = 1
        }
        previewWindow = win

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak win] in
            guard let win = win else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                win.animator().alphaValue = 0
            }, completionHandler: { win.close() })
            if self?.previewWindow == win { self?.previewWindow = nil }
        }
    }

    // MARK: - The menu
    func icon(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    func iconName(for text: String) -> String {
        if text.hasPrefix("[Image:") {
            return "photo"
        }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()

        let isCode = t.contains("{") || t.contains("}") || t.contains("<") || t.contains(">") || t.hasPrefix("func ") || t.hasPrefix("import ") || t.hasPrefix("class ")
        if isCode {
            return "chevron.left.forwardslash.chevron.right"
        }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") {
            return "link"
        }
        if t.contains("@"), t.contains("."), !t.contains(" "), t.count < 60 {
            return "envelope"
        }
        if t.range(of: "^[0-9 +().-]{5,}$", options: .regularExpression) != nil {
            return "number"
        }
        if lower.hasPrefix("file://") || lower.hasPrefix("/") {
            return "doc"
        }
        return "text.alignleft"
    }

    func paintedTitle(for text: String, shortcut: String, isSubmenu: Bool = false, image: NSImage? = nil, extraLabel: String? = nil) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        let tabLocation: CGFloat = isSubmenu ? 295.25 : 300
        para.tabStops = [NSTextTab(textAlignment: .right, location: tabLocation)]
        para.lineBreakMode = .byTruncatingTail

        let title = NSMutableAttributedString()

        if let img = image {
            let targetHeight: CGFloat = 14.0
            let ratio = img.size.width / img.size.height
            let targetWidth = min(targetHeight * ratio, 250.0)

            let scaledImage = NSImage(size: NSSize(width: targetWidth, height: targetHeight))
            scaledImage.lockFocus()
            img.draw(in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            scaledImage.unlockFocus()

            let attachment = NSTextAttachment()
            attachment.image = scaledImage
            attachment.bounds = NSRect(x: 0, y: -2, width: targetWidth, height: targetHeight)

            title.append(NSAttributedString(attachment: attachment))

            if showImageDimensions, text.hasPrefix("[Image: "), text.hasSuffix("]") {
                let dims = text.dropFirst(8).dropLast()
                title.append(NSAttributedString(
                    string: "  \(dims)",
                    attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]))
            }
        } else {
            title.append(NSAttributedString(
                string: text,
                attributes: [.font: NSFont.menuFont(ofSize: 0)]))

            if let extra = extraLabel {
                title.append(NSAttributedString(
                    string: "  \(extra)",
                    attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]))
            }
        }

        title.append(NSAttributedString(
            string: "\t\(shortcut)",
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: para
            ]))
        return title
    }

    // MARK: - NSMenuDelegate & Search/Filter Actions
    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        focusTimer?.invalidate()

        // This timer intelligently keeps filters visible while searching OR if filters are active
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let sf = self.searchField else { return }

            // Check if the search field or its active field editor currently has focus
            let isFocused = (sf.window?.firstResponder == sf) || (sf.currentEditor() != nil && sf.window?.firstResponder == sf.currentEditor())

            // Show the filters ONLY if we are actively focused in the search bar.
            let shouldShow = isFocused

            if let item = self.filtersMenuItem {
                if shouldShow && item.isHidden {
                    item.isHidden = false
                } else if !shouldShow && !item.isHidden {
                    item.isHidden = true
                }
            }
        }
        RunLoop.current.add(timer, forMode: .common)
        self.focusTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        focusTimer?.invalidate()
        focusTimer = nil

        searchField?.window?.makeFirstResponder(nil)

        currentSearchText = ""
        activeFilters.removeAll()
        searchField?.stringValue = ""

        // Smoothly un-highlight custom filter buttons
        if let stack = filtersMenuItem?.view?.subviews.compactMap({ $0 as? NSStackView }).first {
            for v in stack.views {
                if let btn = v as? FilterButton {
                    btn.setSelected(false, animated: false)
                }
            }
        }

        for item in historyMenuItems {
            item.isHidden = false
        }

        if needsRebuildAfterClose {
            needsRebuildAfterClose = false
            rebuildMenu()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        currentSearchText = field.stringValue.lowercased()
        applySearchAndFilter()
    }

    @objc func filterToggled(_ sender: FilterButton) {
        let filterName = sender.identifier?.rawValue ?? ""
        let isActivating = sender.state == .on

        sender.setSelected(isActivating, animated: true)

        if isActivating {
            activeFilters.insert(filterName)
        } else {
            activeFilters.remove(filterName)
        }
        applySearchAndFilter()
    }

    func applySearchAndFilter() {
        for (i, item) in history.enumerated() {
            guard i < historyMenuItems.count else { continue }
            let menuItem = historyMenuItems[i]

            var matchesSearch = true
            if !currentSearchText.isEmpty {
                matchesSearch = item.text.lowercased().contains(currentSearchText)
            }

            var matchesFilter = true
            if !activeFilters.isEmpty {
                var filterMatched = false

                let t = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let textLower = t.lowercased()

                let isImage = item.imageData != nil
                let isCode = t.contains("{") || t.contains("}") || t.contains("<") || t.contains(">") || t.hasPrefix("func ") || t.hasPrefix("import ") || t.hasPrefix("class ")
                let isLink = textLower.hasPrefix("http://") || textLower.hasPrefix("https://") || textLower.hasPrefix("www.")
                let isEmail = t.contains("@") && t.contains(".") && !t.contains(" ") && t.count < 60
                let isNum = t.range(of: "^[0-9 +().-]{5,}$", options: .regularExpression) != nil
                let isFile = textLower.hasPrefix("file://") || textLower.hasPrefix("/")
                let isText = !isImage && !isLink && !isEmail && !isNum && !isCode && !isFile

                if activeFilters.contains("link") && isLink { filterMatched = true }
                if activeFilters.contains("email") && isEmail { filterMatched = true }
                if activeFilters.contains("number") && isNum { filterMatched = true }
                if activeFilters.contains("image") && isImage { filterMatched = true }
                if activeFilters.contains("file") && isFile { filterMatched = true }
                if activeFilters.contains("code") && isCode { filterMatched = true }
                if activeFilters.contains("text") && isText { filterMatched = true }

                if !filterMatched {
                    matchesFilter = false
                }
            }

            menuItem.isHidden = !(matchesSearch && matchesFilter)
        }
    }

    func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let header = NSMenuItem(title: "ClipLocal — History (\(history.count))", action: nil, keyEquivalent: "")
        header.image = icon("doc.on.clipboard")
        let sizeSub = NSMenu()
        let sizeTitle = NSMenuItem(title: "Keep up to…", action: nil, keyEquivalent: "")
        sizeTitle.isEnabled = false
        sizeSub.addItem(sizeTitle)
        sizeSub.addItem(.separator())
        for n in [10, 25, 50, 100, 200] {
            let opt = NSMenuItem(title: "\(n) items", action: #selector(setHistorySize(_:)), keyEquivalent: "")
            opt.target = self
            opt.tag = n
            opt.state = maxItems == n ? .on : .off
            sizeSub.addItem(opt)
        }
        header.submenu = sizeSub
        menu.addItem(header)
        menu.addItem(.separator())

        // --- Search and Filter UI ---
        let searchViewItem = NSMenuItem()
        let searchContainer = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))

        // Using our subclass to fix NSMenu cursor bugs
        let sf = MenuSearchField(frame: .zero)
        sf.placeholderString = "Search history..."
        sf.delegate = self
        sf.focusRingType = .none
        sf.stringValue = currentSearchText
        self.searchField = sf

        sf.translatesAutoresizingMaskIntoConstraints = false
        searchContainer.addSubview(sf)

        NSLayoutConstraint.activate([
            searchContainer.widthAnchor.constraint(equalToConstant: 300),
            searchContainer.heightAnchor.constraint(equalToConstant: 32),
            sf.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 14),
            sf.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -14),
            sf.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            sf.heightAnchor.constraint(equalToConstant: 22)
        ])

        searchViewItem.view = searchContainer
        menu.addItem(searchViewItem)

        let filtersMenuItem = NSMenuItem()
        let filtersContainer = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 32))

        let filters = [
            ("code", "chevron.left.forwardslash.chevron.right"),
            ("email", "envelope"),
            ("file", "doc"),
            ("image", "photo"),
            ("link", "link"),
            ("number", "number"),
            ("text", "text.alignleft")
        ]

        let stack = NSStackView(frame: .zero)
        stack.orientation = .horizontal
        stack.distribution = .equalSpacing
        stack.alignment = .centerY

        stack.translatesAutoresizingMaskIntoConstraints = false
        filtersContainer.addSubview(stack)

        NSLayoutConstraint.activate([
            filtersContainer.widthAnchor.constraint(equalToConstant: 300),
            filtersContainer.heightAnchor.constraint(equalToConstant: 32),
            stack.leadingAnchor.constraint(equalTo: filtersContainer.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: filtersContainer.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: filtersContainer.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 22)
        ])

        // Pre-calculate which filters have items
        var categoryCounts: [String: Int] = [
            "link": 0, "image": 0, "text": 0, "file": 0, "number": 0, "email": 0, "code": 0
        ]

        for item in history {
            let t = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let textLower = t.lowercased()
            let isImage = item.imageData != nil
            let isCode = t.contains("{") || t.contains("}") || t.contains("<") || t.contains(">") || t.hasPrefix("func ") || t.hasPrefix("import ") || t.hasPrefix("class ")
            let isLink = textLower.hasPrefix("http://") || textLower.hasPrefix("https://") || textLower.hasPrefix("www.")
            let isEmail = t.contains("@") && t.contains(".") && !t.contains(" ") && t.count < 60
            let isNum = t.range(of: "^[0-9 +().-]{5,}$", options: .regularExpression) != nil
            let isFile = textLower.hasPrefix("file://") || textLower.hasPrefix("/")
            let isText = !isImage && !isLink && !isEmail && !isNum && !isCode && !isFile

            if isLink { categoryCounts["link"]! += 1 }
            if isImage { categoryCounts["image"]! += 1 }
            if isText { categoryCounts["text"]! += 1 }
            if isFile { categoryCounts["file"]! += 1 }
            if isCode { categoryCounts["code"]! += 1 }
            if isNum { categoryCounts["number"]! += 1 }
            if isEmail { categoryCounts["email"]! += 1 }
        }

        for filter in filters {
            let btn = FilterButton(frame: .zero)
            btn.image = icon(filter.1)
            btn.target = self
            btn.action = #selector(filterToggled(_:))
            btn.identifier = NSUserInterfaceItemIdentifier(filter.0)
            btn.toolTip = "Filter by \(filter.0)"

            let count = categoryCounts[filter.0] ?? 0
            btn.hasItems = count > 0

            let isSelected = activeFilters.contains(filter.0)
            btn.state = isSelected ? .on : .off
            btn.setSelected(isSelected, animated: false)

            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(equalToConstant: 28).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 22).isActive = true
            stack.addView(btn, in: .leading)
        }

        filtersMenuItem.view = filtersContainer
        filtersMenuItem.isHidden = true
        self.filtersMenuItem = filtersMenuItem
        menu.addItem(filtersMenuItem)
        menu.addItem(.separator())
        // --- End Search and Filter UI ---

        historyMenuItems.removeAll()
        if history.isEmpty {
            let empty = NSMenuItem(title: "— empty —", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (i, item) in history.enumerated() {
                var displayText = item.text
                var extraLabel: String? = nil

                let isFile = item.text.hasPrefix("file://") || item.text.hasPrefix("/")
                if isFile {
                    let path = item.text.hasPrefix("file://") ? String(item.text.dropFirst(7)) : item.text
                    let url = URL(fileURLWithPath: path)

                    if showFullFilePath {
                        // When showing full path, filename is text, and minified path is extra
                        let dir = url.deletingLastPathComponent().path
                        // Minify path like /Users/arun/Desktop -> ~/Desktop
                        let home = FileManager.default.homeDirectoryForCurrentUser.path
                        var miniDir = dir.hasPrefix(home) ? "~" + String(dir.dropFirst(home.count)) : dir

                        if miniDir.count > 25 {
                            let prefix = String(miniDir.prefix(10))
                            let suffix = String(miniDir.suffix(12))
                            miniDir = "\(prefix)...\(suffix)"
                        }

                        displayText = url.lastPathComponent
                        extraLabel = miniDir
                    } else {
                        // Just filename
                        displayText = url.lastPathComponent
                    }
                }

                let oneLine = displayText
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let maxLen = extraLabel != nil ? 20 : 34
                let snippet = oneLine.count > maxLen ? String(oneLine.prefix(maxLen)) + "…" : oneLine
                let shortcut = i < 9 ? "\(i + 1)" : ""
                let mi = NSMenuItem(title: snippet,
                                    action: #selector(copyItem(_:)), keyEquivalent: shortcut)
                mi.keyEquivalentModifierMask = [.command]
                mi.image = icon(item.pinned ? "pin.fill" : iconName(for: item.text))
                mi.target = self; mi.tag = i

                var previewImage: NSImage? = nil
                if let data = item.imageData, let loaded = NSImage(data: data) {
                    previewImage = loaded
                }

                if i < 9 || previewImage != nil || extraLabel != nil {
                    let shortcutToPaint = i < 9 ? "⌘\(i + 1)" : ""
                    mi.attributedTitle = paintedTitle(for: snippet, shortcut: shortcutToPaint, isSubmenu: true, image: previewImage, extraLabel: extraLabel)
                }

                let sub = NSMenu()
                let copyA = NSMenuItem(title: "Copy", action: #selector(copyItem(_:)), keyEquivalent: "")
                copyA.image = icon("doc.on.doc")
                copyA.target = self; copyA.tag = i
                let pinA = NSMenuItem(title: item.pinned ? "Unpin" : "Pin",
                                      action: #selector(togglePin(_:)), keyEquivalent: "")
                pinA.image = icon(item.pinned ? "pin.slash" : "pin")
                pinA.target = self; pinA.tag = i
                let delA = NSMenuItem(title: "Delete", action: #selector(deleteItem(_:)), keyEquivalent: "")
                delA.image = icon("trash")
                delA.target = self; delA.tag = i
                sub.addItem(copyA); sub.addItem(pinA); sub.addItem(.separator()); sub.addItem(delA)
                mi.submenu = sub
                menu.addItem(mi)
                historyMenuItems.append(mi)
            }
        }
        menu.addItem(.separator())

        applySearchAndFilter()

        let clear = NSMenuItem(title: "Clear History Now", action: #selector(clearNow), keyEquivalent: "")
        clear.attributedTitle = paintedTitle(for: "Clear History Now", shortcut: "⌘⌫")
        clear.image = icon("trash.fill")
        clear.target = self
        menu.addItem(clear)
        let hiddenClear = NSMenuItem(title: "", action: #selector(clearNow), keyEquivalent: "\u{8}")
        hiddenClear.keyEquivalentModifierMask = [.command]
        hiddenClear.target = self
        hiddenClear.isHidden = true
        menu.addItem(hiddenClear)

        menu.addItem(.separator())

        let prefs = NSMenuItem(title: "Preferences…", action: nil, keyEquivalent: "")
        prefs.attributedTitle = paintedTitle(for: "Preferences…", shortcut: "⌘,", isSubmenu: true)
        prefs.image = icon("gearshape")
        let prefsSub = NSMenu()

        let privacy = NSMenuItem(title: "History Storage", action: nil, keyEquivalent: "")
        privacy.image = icon("lock.shield")
        let psub = NSMenu()
        let sessionItem = NSMenuItem(title: "Session-only (wiped on quit)",
                                     action: #selector(setSession), keyEquivalent: "")
        sessionItem.image = icon("lock")
        sessionItem.target = self
        sessionItem.state = mode == .session ? .on : .off
        let persistItem = NSMenuItem(title: "Persistent (kept on quit)",
                                     action: #selector(setPersistent), keyEquivalent: "")
        persistItem.image = icon("externaldrive.fill")
        persistItem.target = self
        persistItem.state = mode == .persistent ? .on : .off
        psub.addItem(sessionItem); psub.addItem(persistItem)
        privacy.submenu = psub
        prefsSub.addItem(privacy)

        let skip = NSMenuItem(title: "Skip password-manager copies",
                              action: #selector(toggleSkip), keyEquivalent: "")
        skip.image = icon("key.fill")
        skip.target = self
        skip.state = skipConcealed ? .on : .off
        prefsSub.addItem(skip)

        let showDims = NSMenuItem(title: "Show image dimensions",
                                  action: #selector(toggleShowImageDimensions), keyEquivalent: "")
        showDims.image = icon("photo.on.rectangle.angled")
        showDims.target = self
        showDims.state = showImageDimensions ? .on : .off
        prefsSub.addItem(showDims)

        let showPaths = NSMenuItem(title: "Show full file paths",
                                  action: #selector(toggleShowFullFilePath), keyEquivalent: "")
        showPaths.image = icon("folder")
        showPaths.target = self
        showPaths.state = showFullFilePath ? .on : .off
        prefsSub.addItem(showPaths)

        let launch = NSMenuItem(title: "Launch at Login",
                                action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.image = icon("power")
        launch.target = self
        launch.state = launchAtLoginEnabled ? .on : .off
        prefsSub.addItem(launch)

        prefs.submenu = prefsSub
        menu.addItem(prefs)

        let hiddenPrefs = NSMenuItem(title: "", action: nil, keyEquivalent: ",")
        hiddenPrefs.keyEquivalentModifierMask = [.command]
        hiddenPrefs.target = self
        hiddenPrefs.isHidden = true
        menu.addItem(hiddenPrefs)

        menu.addItem(.separator())
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesMenu), keyEquivalent: "")
        updates.image = icon("arrow.triangle.2.circlepath")
        updates.target = self
        menu.addItem(updates)
        let about = NSMenuItem(title: "About ClipLocal", action: #selector(showAboutMenu), keyEquivalent: "")
        about.image = icon("info.circle")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "")
        quit.attributedTitle = paintedTitle(for: "Quit", shortcut: "⌘Q")
        quit.image = icon("xmark.circle")
        quit.target = self
        menu.addItem(quit)
        let hiddenQuit = NSMenuItem(title: "", action: #selector(quitApp), keyEquivalent: "q")
        hiddenQuit.keyEquivalentModifierMask = [.command]
        hiddenQuit.target = self
        hiddenQuit.isHidden = true
        menu.addItem(hiddenQuit)

        statusItem.menu = menu
    }

    // MARK: - Menu actions
    @objc func copyItem(_ sender: NSMenuItem) {
        let i = sender.tag
        guard i < history.count else { return }
        let item = history[i]
        let pb = NSPasteboard.general
        pb.clearContents()

        if let data = item.imageData, let img = NSImage(data: data) {
            pb.setData(data, forType: .png)
            if let tiff = img.tiffRepresentation {
                pb.setData(tiff, forType: .tiff)
            }
        } else if (item.text.hasPrefix("/") || item.text.hasPrefix("file://")) && FileManager.default.fileExists(atPath: item.text.hasPrefix("file://") ? String(item.text.dropFirst(7)) : item.text) {
            let path = item.text.hasPrefix("file://") ? String(item.text.dropFirst(7)) : item.text
            let url = URL(fileURLWithPath: path)
            pb.writeObjects([url as NSURL])
            pb.setString(item.text, forType: .string)
        } else {
            pb.setString(item.text, forType: .string)
        }

        lastChangeCount = pb.changeCount
        let pinned = item.pinned
        history.remove(at: i)
        history.insert(ClipItem(text: item.text, date: Date(), pinned: pinned, imageData: item.imageData), at: 0)
        persistIfNeeded()
        rebuildMenu()
    }

    @objc func togglePin(_ sender: NSMenuItem) {
        let i = sender.tag
        guard i < history.count else { return }
        history[i].pinned.toggle()
        persistIfNeeded()
        rebuildMenu()
    }

    @objc func deleteItem(_ sender: NSMenuItem) {
        let i = sender.tag
        guard i < history.count else { return }
        history.remove(at: i)
        persistIfNeeded()
        rebuildMenu()
    }

    @objc func setSession() { mode = .session; deleteStore() }
    @objc func setPersistent() { mode = .persistent; saveHistory() }
    @objc func toggleSkip() { skipConcealed.toggle() }
    @objc func toggleShowImageDimensions() { showImageDimensions.toggle() }
    @objc func toggleShowFullFilePath() { showFullFilePath.toggle() }

    @objc func setHistorySize(_ sender: NSMenuItem) {
        maxItems = sender.tag
        trimHistory()
        persistIfNeeded()
        rebuildMenu()
    }

    // MARK: - Launch at Login
    var launchAtLoginEnabled: Bool {
        return SMAppService.mainApp.status == .enabled
    }

    @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "macOS blocked the change. You can also manage this in System Settings → General → Login Items."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc func clearNow() {
        history = history.filter { $0.pinned }
        if history.isEmpty {
            deleteStore()
        } else {
            persistIfNeeded()
        }
        rebuildMenu()
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    // MARK: - Update check
    @objc func checkForUpdatesMenu() { checkForUpdates(silentIfCurrent: false) }

    func checkForUpdates(silentIfCurrent: Bool) {
        guard let url = URL(string: updateCheckURL) else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self else { return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let remote = json["version"] as? String else {
                if !silentIfCurrent {
                    DispatchQueue.main.async { self.showUpdateResult(nil, changelog: "", newer: false) }
                }
                return
            }
            let dl = (json["downloadURL"] as? String) ?? downloadPageURL
            var notes = ""
            if let logs = json["changelog"] as? [[String: Any]],
               let entry = logs.first(where: { ($0["version"] as? String) == remote }),
               let changes = entry["changes"] as? [String] {
                notes = changes.map { "•  \($0)" }.joined(separator: "\n")
            }
            let newer = self.isNewer(remote, than: appVersion)
            DispatchQueue.main.async {
                if newer {
                    self.showUpdateResult(remote, changelog: notes, newer: true, downloadURL: dl)
                } else if !silentIfCurrent {
                    self.showUpdateResult(remote, changelog: notes, newer: false)
                }
            }
        }
        task.resume()
    }

    func isNewer(_ remote: String, than current: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv > cv { return true }
            if rv < cv { return false }
        }
        return false
    }

    func showUpdateResult(_ remote: String?, changelog: String, newer: Bool, downloadURL: String = downloadPageURL) {
        let alert = NSAlert()
        NSApp.activate(ignoringOtherApps: true)
        if newer, let remote = remote {
            alert.messageText = "ClipLocal \(remote) is available"
            alert.informativeText = "You have v\(appVersion). Here's what's new:"
            if !changelog.isEmpty {
                let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 130))
                tv.isEditable = false; tv.drawsBackground = false
                tv.font = NSFont.systemFont(ofSize: 12)
                tv.string = changelog
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 130))
                scroll.hasVerticalScroller = true; scroll.drawsBackground = false
                scroll.documentView = tv
                alert.accessoryView = scroll
            }
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: downloadURL) {
                NSWorkspace.shared.open(url)
            }
        } else if remote != nil {
            alert.messageText = "You're up to date"
            alert.informativeText = "ClipLocal v\(appVersion) is the latest version."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } else {
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "Please check your internet connection and try again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Encrypted persistence
    var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipLocal")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.enc")
    }

    func persistIfNeeded() { if mode == .persistent { saveHistory() } }

    func saveHistory() {
        do {
            let data = try JSONEncoder().encode(history)
            let sealed = try AES.GCM.seal(data, using: key)
            if let combined = sealed.combined {
                try combined.write(to: storeURL, options: .completeFileProtection)
            }
        } catch { }
    }

    func loadHistory() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            let dec = try AES.GCM.open(box, using: key)
            history = try JSONDecoder().decode([ClipItem].self, from: dec)
        } catch { }
    }

    func deleteStore() { try? FileManager.default.removeItem(at: storeURL) }
}

// MARK: - Launch
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
