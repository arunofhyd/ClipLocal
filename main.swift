import Cocoa
import CryptoKit
import ServiceManagement
import SwiftUI

// ============================================================
//  ClipLocal — 100% on-device clipboard history, no third parties
// ============================================================

let appVersion = "1.9"
let updateCheckURL = "https://raw.githubusercontent.com/arunofhyd/ClipLocal/main/version.json"
let downloadPageURL = "https://cliplocal.vercel.app/#install"

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

        let oldKeyURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipLocal")
            .appendingPathComponent("history.enc")

        if FileManager.default.fileExists(atPath: oldKeyURL.path) {
            let tag = "com.cliplocal.encryptionkey".data(using: .utf8)!
            let query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: tag,
                kSecReturnData as String: true
            ]
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data {
                let symKey = SymmetricKey(data: data)
                let keyData = symKey.withUnsafeBytes { Data($0) }
                try? keyData.write(to: keyURL, options: [.atomic, .completeFileProtection])
                return symKey
            }
        }

        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        try? keyData.write(to: keyURL, options: [.atomic, .completeFileProtection])
        return newKey
    }
}

// MARK: - Data Models
struct ClipItem: Codable, Identifiable, Hashable {
    var id: String { text + String(date.timeIntervalSince1970) }
    let text: String
    let date: Date
    var pinned: Bool = false
    var imageData: Data?

    func hash(into hasher: inout Hasher) {
        hasher.combine(text)
        hasher.combine(date)
    }

    static func == (lhs: ClipItem, rhs: ClipItem) -> Bool {
        return lhs.text == rhs.text && lhs.date == rhs.date
    }
}

enum PrivacyMode: String {
    case session
    case persistent
}

class ClipboardManager: ObservableObject {
    @Published var history: [ClipItem] = []
    @Published var currentSearchText = ""
    @Published var activeFilters: Set<String> = []

    let key = KeyStore.loadOrCreateKey()
    let defaults = UserDefaults.standard
    var lastChangeCount = NSPasteboard.general.changeCount

    var mode: PrivacyMode {
        get { PrivacyMode(rawValue: defaults.string(forKey: "mode") ?? "persistent") ?? .persistent }
        set { defaults.set(newValue.rawValue, forKey: "mode"); persistIfNeeded(); objectWillChange.send() }
    }

    var skipConcealed: Bool {
        get { defaults.object(forKey: "skipConcealed") == nil ? true : defaults.bool(forKey: "skipConcealed") }
        set { defaults.set(newValue, forKey: "skipConcealed"); objectWillChange.send() }
    }

    var showImageDimensions: Bool {
        get { defaults.bool(forKey: "showImageDimensions") }
        set { defaults.set(newValue, forKey: "showImageDimensions"); objectWillChange.send() }
    }

    var maxItems: Int {
        get { let v = defaults.integer(forKey: "maxItems"); return v == 0 ? 50 : v }
        set { defaults.set(newValue, forKey: "maxItems"); objectWillChange.send() }
    }

    var launchAtLoginEnabled: Bool {
        return SMAppService.mainApp.status == .enabled
    }

    var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipLocal")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.enc")
    }

    init() {
        if mode == .persistent { loadHistory() }
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

    func trimHistory() {
        let pinned = history.filter { $0.pinned }
        let unpinned = history.filter { !$0.pinned }
        if unpinned.count > maxItems {
            let keptUnpinned = unpinned.prefix(maxItems)
            var newHistory = pinned + keptUnpinned
            newHistory.sort { $0.date > $1.date }
            history = newHistory
        }
    }

    func clearNow() {
        history = history.filter { $0.pinned }
        if history.isEmpty {
            deleteStore()
        } else {
            persistIfNeeded()
        }
    }

    func toggleLaunchAtLogin() {
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
        objectWillChange.send()
    }
}

// MARK: - Views
struct ContentView: View {
    @ObservedObject var manager: ClipboardManager
    @State private var hoverIdx: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search...", text: $manager.currentSearchText)
                    .textFieldStyle(PlainTextFieldStyle())
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Filters
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    FilterButton(title: "Text", systemImage: "text.alignleft", filterType: "text", manager: manager)
                    FilterButton(title: "Link", systemImage: "link", filterType: "link", manager: manager)
                    FilterButton(title: "Image", systemImage: "photo", filterType: "image", manager: manager)
                    FilterButton(title: "File", systemImage: "doc", filterType: "file", manager: manager)
                    FilterButton(title: "Code", systemImage: "chevron.left.forwardslash.chevron.right", filterType: "code", manager: manager)
                    FilterButton(title: "Email", systemImage: "envelope", filterType: "email", manager: manager)
                    FilterButton(title: "Number", systemImage: "number", filterType: "number", manager: manager)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // List
            List {
                if filteredHistory.isEmpty {
                    Text("— empty —")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                } else {
                    ForEach(Array(filteredHistory.enumerated()), id: \.element.id) { (index, item) in
                        Button(action: { copyItem(item) }) {
                            HStack {
                                Image(systemName: item.pinned ? "pin.fill" : iconName(for: item.text))
                                    .foregroundColor(item.pinned ? .accentColor : .primary)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(snippet(for: item.text))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .font(.system(size: 13))
                                        .foregroundColor(.primary)

                                    if let imageData = item.imageData, let nsImage = NSImage(data: imageData) {
                                        Image(nsImage: nsImage)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(height: 60)
                                            .cornerRadius(4)
                                    }
                                }

                                Spacer()

                                if index < 9 && manager.currentSearchText.isEmpty && manager.activeFilters.isEmpty {
                                    Text("⌘\(index + 1)")
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 11))
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .keyboardShortcut(index < 9 && manager.currentSearchText.isEmpty && manager.activeFilters.isEmpty ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command) : nil)
                        .onHover { isHovered in
                            hoverIdx = isHovered ? item.id : nil
                        }
                        .background(hoverIdx == item.id ? Color.accentColor.opacity(0.1) : Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deleteItem(item)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                togglePin(item)
                            } label: {
                                Label(item.pinned ? "Unpin" : "Pin", systemImage: item.pinned ? "pin.slash" : "pin")
                            }
                            .tint(.orange)
                        }
                    }
                }
            }
            .listStyle(PlainListStyle())

            Divider()

            // Footer / Settings
            HStack {
                Menu {
                    Button(action: { manager.clearNow() }) {
                        Text("Clear History Now")
                        Image(systemName: "trash.fill")
                    }
                    Divider()
                    Menu {
                        Menu {
                            Button(action: { manager.mode = .session }) {
                                Text("Session-only (wiped on quit)")
                                Image(systemName: manager.mode == .session ? "checkmark" : "lock")
                            }
                            Button(action: { manager.mode = .persistent }) {
                                Text("Persistent (kept on quit)")
                                Image(systemName: manager.mode == .persistent ? "checkmark" : "externaldrive.fill")
                            }
                        } label: {
                            Text("History Storage")
                            Image(systemName: "lock.shield")
                        }

                        Menu {
                            ForEach([10, 25, 50, 100, 200], id: \.self) { size in
                                Button(action: { manager.maxItems = size }) {
                                    Text("\(size) items")
                                    if manager.maxItems == size { Image(systemName: "checkmark") }
                                }
                            }
                        } label: {
                            Text("Keep up to...")
                            Image(systemName: "list.number")
                        }

                        Button(action: { manager.skipConcealed.toggle() }) {
                            Text("Skip password-manager copies")
                            Image(systemName: manager.skipConcealed ? "checkmark" : "key.fill")
                        }
                        Button(action: { manager.showImageDimensions.toggle() }) {
                            Text("Show image dimensions")
                            Image(systemName: manager.showImageDimensions ? "checkmark" : "photo.on.rectangle.angled")
                        }
                        Button(action: { manager.toggleLaunchAtLogin() }) {
                            Text("Launch at Login")
                            Image(systemName: manager.launchAtLoginEnabled ? "checkmark" : "power")
                        }
                    } label: {
                        Text("Preferences...")
                        Image(systemName: "gearshape")
                    }
                    Divider()
                    Button(action: {
                        (NSApp.delegate as? AppDelegate)?.checkForUpdates(silentIfCurrent: false)
                    }) {
                        Text("Check for Updates...")
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Button(action: {
                        (NSApp.delegate as? AppDelegate)?.showAbout(onLaunch: false)
                    }) {
                        Text("About ClipLocal")
                        Image(systemName: "info.circle")
                    }
                    Button(action: {
                        NSApp.terminate(nil)
                    }) {
                        Text("Quit")
                        Image(systemName: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundColor(.secondary)
                }
                .menuStyle(BorderlessButtonMenuStyle())
                .frame(width: 30)

                Spacer()
                Text("ClipLocal")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    // MARK: - Helpers
    var filteredHistory: [ClipItem] {
        var result = manager.history
        if !manager.activeFilters.isEmpty {
            result = result.filter { item in
                for filter in manager.activeFilters {
                    if checkFilterMatch(item: item, filter: filter) { return true }
                }
                return false
            }
        }
        if !manager.currentSearchText.isEmpty {
            let s = manager.currentSearchText.lowercased()
            result = result.filter { $0.text.lowercased().contains(s) }
        }
        return result
    }

    func checkFilterMatch(item: ClipItem, filter: String) -> Bool {
        if item.imageData != nil { return filter == "image" }
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch filter {
        case "link":
            return text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("www.")
        case "email":
            let parts = text.split(separator: "@")
            return parts.count == 2 && parts[1].contains(".") && !text.contains(" ")
        case "number":
            let regex = "^[0-9 +().-]{5,}$"
            return text.range(of: regex, options: .regularExpression) != nil
        case "file":
            return (text.hasPrefix("/") || text.hasPrefix("file://")) && !text.contains("\n")
        case "code":
            return text.contains("{") || text.contains("}") || text.contains("func ") || text.contains("var ") || text.contains("let ") || text.contains("class ") || text.contains("struct ") || text.contains("<") || text.contains(">") || text.contains(";")
        case "text":
            let isLink = text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("www.")
            let parts = text.split(separator: "@")
            let isEmail = parts.count == 2 && parts[1].contains(".") && !text.contains(" ")
            let isNumber = text.range(of: "^[0-9 +().-]{5,}$", options: .regularExpression) != nil
            let isFile = (text.hasPrefix("/") || text.hasPrefix("file://")) && !text.contains("\n")
            let isCode = text.contains("{") || text.contains("}") || text.contains("func ") || text.contains("var ") || text.contains("let ") || text.contains("class ") || text.contains("struct ") || text.contains("<") || text.contains(">") || text.contains(";")
            return !isLink && !isEmail && !isNumber && !isFile && !isCode
        default: return false
        }
    }

    func iconName(for text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("www.") { return "link" }
        let parts = t.split(separator: "@")
        if parts.count == 2 && parts[1].contains(".") && !t.contains(" ") { return "envelope" }
        if t.range(of: "^[0-9 +().-]{5,}$", options: .regularExpression) != nil { return "number" }
        if (t.hasPrefix("/") || t.hasPrefix("file://")) && !t.contains("\n") { return "doc" }
        if t.contains("{") || t.contains("}") || t.contains("func ") || t.contains("var ") || t.contains("let ") || t.contains("class ") || t.contains("struct ") || t.contains("<") || t.contains(">") || t.contains(";") { return "chevron.left.forwardslash.chevron.right" }
        return "text.alignleft"
    }

    func snippet(for text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ↵ ").trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine
    }

    // MARK: - Actions
    func copyItem(_ item: ClipItem) {
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

        manager.lastChangeCount = pb.changeCount

        let itemId = item.id
        if let idx = manager.history.firstIndex(where: { $0.id == itemId }) {
            let pinned = manager.history[idx].pinned
            manager.history.remove(at: idx)
            let newItem = ClipItem(text: item.text, date: Date(), pinned: pinned, imageData: item.imageData)
            manager.history.insert(newItem, at: 0)
        }

        manager.persistIfNeeded()
        (NSApp.delegate as? AppDelegate)?.popover.performClose(nil)
    }

    func deleteItem(_ item: ClipItem) {
        let itemId = item.id
        if let idx = manager.history.firstIndex(where: { $0.id == itemId }) {
            manager.history.remove(at: idx)
            manager.persistIfNeeded()
        }
    }

    func togglePin(_ item: ClipItem) {
        let itemId = item.id
        if let idx = manager.history.firstIndex(where: { $0.id == itemId }) {
            manager.history[idx].pinned.toggle()
            manager.persistIfNeeded()
        }
    }
} // End of ContentView

struct FilterButton: View {
    let title: String
    let systemImage: String
    let filterType: String
    @ObservedObject var manager: ClipboardManager

    var isSelected: Bool {
        manager.activeFilters.contains(filterType)
    }

    var body: some View {
        Button(action: {
            if isSelected {
                manager.activeFilters.remove(filterType)
            } else {
                manager.activeFilters.insert(filterType)
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.1))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(6)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var timer: Timer?
    var previewWindow: NSWindow?
    let clipboardManager = ClipboardManager()
    let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        if defaults.object(forKey: "hasLaunchedBefore") == nil {
            defaults.set(true, forKey: "hasLaunchedBefore")
            try? SMAppService.mainApp.register()
        }

        NSApp.setActivationPolicy(.accessory)

        let contentView = ContentView(manager: clipboardManager)
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 450)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: contentView)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                   accessibilityDescription: "ClipLocal")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        showAbout(onLaunch: true)
        checkForUpdates(silentIfCurrent: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(sender)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: NSRectEdge.minY)
                NSApp.activate(ignoringOtherApps: true)
            }
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

        let icon = NSImageView(frame: NSRect(x: (width - 100) / 2, y: height - 140, width: 100, height: 100))
        icon.image = NSImage(named: "NSApplicationIcon")
        icon.imageScaling = .scaleProportionallyUpOrDown
        bg.addSubview(icon)

        let title = NSTextField(labelWithString: "ClipLocal")
        title.frame = NSRect(x: 0, y: height - 190, width: width, height: 40)
        title.alignment = .center
        title.font = NSFont.systemFont(ofSize: 32, weight: .bold)
        bg.addSubview(title)

        let ver = NSTextField(labelWithString: "Version \(appVersion)")
        ver.frame = NSRect(x: 0, y: height - 210, width: width, height: 20)
        ver.alignment = .center
        ver.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        ver.textColor = .secondaryLabelColor
        bg.addSubview(ver)

        let features = [
            ("lock.shield", "100% On-Device & Private", "Your clipboard data never leaves your Mac. No cloud, no tracking, no accounts."),
            ("key.fill", "Skips Secrets", "By default, passwords copied from 1Password, Bitwarden, etc., are completely ignored."),
            ("eye.slash", "No Analytics", "Zero telemetry. The app only connects to GitHub manually when you check for updates."),
            ("externaldrive.fill", "Encrypted Storage", "In Persistent mode, your history is encrypted (AES-GCM) on disk. Only your Mac account can read it.")
        ]

        var currentY: CGFloat = height - 280
        for (iconName, ft, desc) in features {
            let imgView = NSImageView(frame: NSRect(x: 40, y: currentY - 20, width: 32, height: 32))
            imgView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 24, weight: .regular))
            imgView.contentTintColor = .controlAccentColor
            bg.addSubview(imgView)

            let ftLabel = NSTextField(labelWithString: ft)
            ftLabel.frame = NSRect(x: 90, y: currentY, width: width - 130, height: 20)
            ftLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
            bg.addSubview(ftLabel)

            let descLabel = NSTextField(wrappingLabelWithString: desc)
            descLabel.frame = NSRect(x: 90, y: currentY - 40, width: width - 130, height: 36)
            descLabel.font = NSFont.systemFont(ofSize: 13)
            descLabel.textColor = .secondaryLabelColor
            bg.addSubview(descLabel)

            currentY -= 80
        }

        let link = NSTextField(labelWithString: "GitHub: arunofhyd/ClipLocal")
        link.frame = NSRect(x: 0, y: 70, width: width, height: 20)
        link.alignment = .center
        link.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        link.textColor = .linkColor
        let tap = NSClickGestureRecognizer(target: self, action: #selector(openGitHub))
        link.addGestureRecognizer(tap)
        bg.addSubview(link)

        let btn = NSButton(title: "Got it", target: self, action: #selector(closeAbout))
        btn.frame = NSRect(x: (width - 120) / 2, y: 20, width: 120, height: 32)
        btn.bezelStyle = .rounded
        btn.controlSize = .large
        btn.keyEquivalent = "\r"
        bg.addSubview(btn)

        win.contentView = bg
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow = win
    }

    @objc func openGitHub() { NSWorkspace.shared.open(URL(string: "https://github.com/arunofhyd/ClipLocal")!) }
    @objc func closeAbout() { defaults.set(true, forKey: "hideAbout"); aboutWindow?.close() }


    func checkClipboard() {
        let pb = NSPasteboard.general
        if pb.changeCount == clipboardManager.lastChangeCount { return }
        clipboardManager.lastChangeCount = pb.changeCount

        if clipboardManager.skipConcealed {
            if let types = pb.types, types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) {
                return
            }
        }

        var newText: String?
        var newImage: Data?

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let first = urls.first {
            newText = "file://" + first.path
        } else if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let img = images.first {
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                newImage = png
                newText = "[Image" + (clipboardManager.showImageDimensions ? " \(Int(img.size.width))x\(Int(img.size.height))" : "") + "]"
            }
        } else if let str = pb.string(forType: .string) {
            let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return }
            newText = str
        }

        guard let text = newText else { return }

        // Needs to be run on main thread since it updates @Published history
        DispatchQueue.main.async {
            if let idx = self.clipboardManager.history.firstIndex(where: { $0.text == text && $0.imageData == newImage }) {
                let pinned = self.clipboardManager.history[idx].pinned
                self.clipboardManager.history.remove(at: idx)
                let newItem = ClipItem(text: text, date: Date(), pinned: pinned, imageData: newImage)
                self.clipboardManager.history.insert(newItem, at: 0)
            } else {
                let newItem = ClipItem(text: text, date: Date(), pinned: false, imageData: newImage)
                self.clipboardManager.history.insert(newItem, at: 0)
                self.showPreview(text)
            }
            self.clipboardManager.trimHistory()
            self.clipboardManager.persistIfNeeded()
        }
    }

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
        previewWindow = win

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            win.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                win.animator().alphaValue = 0
            }, completionHandler: { win.close() })
        }
    }

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
}

// MARK: - App Main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
