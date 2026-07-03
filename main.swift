import Cocoa
import CryptoKit
import ServiceManagement

// ============================================================
//  ClipLocal — 100% on-device clipboard history, no third parties
// ============================================================

let appVersion = "1.1"
// The update check reads this small file from your GitHub. It's the ONLY
// network request the app ever makes. Nothing else leaves the Mac.
let updateCheckURL = "https://raw.githubusercontent.com/arunofhyd/ClipLocal/main/version.json"
let downloadPageURL = "https://cliplocal.vercel.app/#install"

// MARK: - Encryption key (stored in a protected local file, NOT the Keychain,
//         so macOS never shows a scary Keychain-access prompt).
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
        // Write with owner-only permissions (0600) and file protection.
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
}

enum PrivacyMode: String {
    case session
    case persistent
}

// MARK: - The app
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var lastChangeCount = NSPasteboard.general.changeCount
    var history: [ClipItem] = []
    let key = KeyStore.loadOrCreateKey()
    let defaults = UserDefaults.standard
    var previewWindow: NSWindow?

    var mode: PrivacyMode {
        get { PrivacyMode(rawValue: defaults.string(forKey: "mode") ?? "session") ?? .session }
        set { defaults.set(newValue.rawValue, forKey: "mode"); persistIfNeeded(); rebuildMenu() }
    }
    var skipConcealed: Bool {
        get { defaults.object(forKey: "skipConcealed") == nil ? true : defaults.bool(forKey: "skipConcealed") }
        set { defaults.set(newValue, forKey: "skipConcealed"); rebuildMenu() }
    }
    var maxItems: Int {
        get { let v = defaults.integer(forKey: "maxItems"); return v == 0 ? 50 : v }
        set { defaults.set(newValue, forKey: "maxItems"); rebuildMenu() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        let width: CGFloat = 460, height: CGFloat = 560
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

        // App glyph
        let icon = NSImageView(frame: NSRect(x: (width - 72)/2, y: height - 128, width: 72, height: 72))
        let cfg = NSImage.SymbolConfiguration(pointSize: 60, weight: .regular)
        icon.image = NSImage(systemSymbolName: "lock.doc.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        icon.contentTintColor = NSColor.controlAccentColor
        bg.addSubview(icon)

        let name = NSTextField(labelWithString: "ClipLocal")
        name.frame = NSRect(x: 0, y: height - 172, width: width, height: 32)
        name.alignment = .center
        name.font = NSFont.systemFont(ofSize: 26, weight: .bold)
        bg.addSubview(name)

        let version = NSTextField(labelWithString: "Version \(appVersion)")
        version.frame = NSRect(x: 0, y: height - 194, width: width, height: 16)
        version.alignment = .center
        version.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        version.textColor = .tertiaryLabelColor
        bg.addSubview(version)

        let tagline = NSTextField(labelWithString: "Your clipboard. Yours alone.")
        tagline.frame = NSRect(x: 0, y: height - 214, width: width, height: 18)
        tagline.alignment = .center
        tagline.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        tagline.textColor = .secondaryLabelColor
        bg.addSubview(tagline)

        // Privacy body
        let privacy = NSTextView(frame: NSRect(x: 40, y: 125, width: width - 80, height: 200))
        privacy.isEditable = false
        privacy.isSelectable = false
        privacy.drawsBackground = false
        privacy.textContainerInset = NSSize(width: 0, height: 0)
        let bodyText = """
        🔒  100% on-device. Your clipboard data NEVER leaves your Mac — no cloud, no servers, no accounts, no analytics, no third parties. Ever.

        💾  In Persistent mode, history is encrypted with a key stored in a protected file that only your macOS account can read.

        🔑  Session-only mode keeps everything in memory and wipes it the moment you quit.

        🛡️  Copies from password managers are skipped by default, and you can clear everything instantly anytime.
        """
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        let attr = NSMutableAttributedString(string: bodyText, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ])
        privacy.textStorage?.setAttributedString(attr)
        bg.addSubview(privacy)

        // Credit
        let credit = NSTextField(labelWithString: "Built by Arun Thomas")
        credit.frame = NSRect(x: 0, y: 104, width: width, height: 18)
        credit.alignment = .center
        credit.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        credit.textColor = .secondaryLabelColor
        bg.addSubview(credit)

        // "Don't show again" toggle — sized to content and centered.
        let dontShow = NSButton(checkboxWithTitle: "Don't show again",
                                target: self, action: #selector(toggleHideAbout(_:)))
        dontShow.font = NSFont.systemFont(ofSize: 11)
        dontShow.sizeToFit()
        let dsW = dontShow.frame.width
        dontShow.frame = NSRect(x: (width - dsW)/2, y: 72, width: dsW, height: 20)
        dontShow.state = defaults.bool(forKey: "hideAbout") ? .on : .off
        bg.addSubview(dontShow)

        let contact = NSButton(title: "Contact", target: self, action: #selector(contactDeveloper))
        contact.frame = NSRect(x: 40, y: 24, width: 100, height: 32)
        contact.bezelStyle = .rounded
        bg.addSubview(contact)

        let close = NSButton(title: "Get Started", target: self, action: #selector(closeAbout))
        close.frame = NSRect(x: width - 160, y: 24, width: 120, height: 32)
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

        guard let text = pb.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        var pinned = false
        if let idx = history.firstIndex(where: { $0.text == text }) {
            pinned = history[idx].pinned
            history.remove(at: idx)
        }
        history.insert(ClipItem(text: text, date: Date(), pinned: pinned), at: 0)
        trimHistory()
        persistIfNeeded()
        rebuildMenu()
        showPreview(text)
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

    // Pick a relevant SF Symbol based on what the copied text looks like.
    func iconName(for text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") {
            return "link"
        }
        if t.contains("@"), t.contains("."), !t.contains(" "), t.count < 60 {
            return "envelope"
        }
        if t.range(of: "^[0-9 +().-]{5,}$", options: .regularExpression) != nil {
            return "number"
        }
        if t.contains("\n") || t.count > 60 {
            return "doc.plaintext"
        }
        return "textformat"
    }

    func rebuildMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "ClipLocal — History (\(history.count))", action: nil, keyEquivalent: "")
        header.image = icon("doc.on.clipboard")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if history.isEmpty {
            let empty = NSMenuItem(title: "— empty —", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (i, item) in history.enumerated() {
                let snippet = String(item.text.prefix(50)).replacingOccurrences(of: "\n", with: " ")
                // First 9 items get a 1–9 shortcut: press the number to copy.
                let shortcut = i < 9 ? "\(i + 1)" : ""
                let mi = NSMenuItem(title: snippet,
                                    action: #selector(copyItem(_:)), keyEquivalent: shortcut)
                mi.image = icon(item.pinned ? "pin.fill" : iconName(for: item.text))
                mi.keyEquivalentModifierMask = []   // just the number, no ⌘
                mi.target = self; mi.tag = i

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
            }
        }
        menu.addItem(.separator())

        let privacy = NSMenuItem(title: "Privacy Mode", action: nil, keyEquivalent: "")
        privacy.image = icon("lock.shield")
        let psub = NSMenu()
        let sessionItem = NSMenuItem(title: "Session-only (wiped on quit)",
                                     action: #selector(setSession), keyEquivalent: "")
        sessionItem.image = icon("lock")
        sessionItem.target = self
        sessionItem.state = mode == .session ? .on : .off
        let persistItem = NSMenuItem(title: "Persistent (encrypted)",
                                     action: #selector(setPersistent), keyEquivalent: "")
        persistItem.image = icon("externaldrive.fill")
        persistItem.target = self
        persistItem.state = mode == .persistent ? .on : .off
        psub.addItem(sessionItem); psub.addItem(persistItem)
        privacy.submenu = psub
        menu.addItem(privacy)

        let skip = NSMenuItem(title: "Skip password-manager copies",
                              action: #selector(toggleSkip), keyEquivalent: "")
        skip.image = icon("key.fill")
        skip.target = self
        skip.state = skipConcealed ? .on : .off
        menu.addItem(skip)

        let launch = NSMenuItem(title: "Launch at Login",
                                action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.image = icon("power")
        launch.target = self
        launch.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear History Now", action: #selector(clearNow), keyEquivalent: "\u{8}")
        clear.image = icon("trash.fill")
        clear.keyEquivalentModifierMask = [.command]
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesMenu), keyEquivalent: "")
        updates.image = icon("arrow.triangle.2.circlepath")
        updates.target = self
        menu.addItem(updates)
        let about = NSMenuItem(title: "About ClipLocal", action: #selector(showAboutMenu), keyEquivalent: "")
        about.image = icon("info.circle")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.image = icon("xmark.circle")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Menu actions
    @objc func copyItem(_ sender: NSMenuItem) {
        let i = sender.tag
        guard i < history.count else { return }
        let text = history[i].text
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount // don't re-capture our own copy
        let pinned = history[i].pinned
        history.remove(at: i)
        history.insert(ClipItem(text: text, date: Date(), pinned: pinned), at: 0)
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
        history.removeAll()
        deleteStore()
        rebuildMenu()
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    // MARK: - Update check (the ONLY network request the app makes)
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
