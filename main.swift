import Cocoa
import SwiftUI
import ServiceManagement

// ============================================================
//  ClipLocal — 100% on-device clipboard history, no third parties
// ============================================================

let appVersion = "1.1.8"
let updateCheckURL = "https://raw.githubusercontent.com/arunofhyd/ClipLocal/main/version.json"
let downloadPageURL = "https://cliplocal.vercel.app/#install"

// MARK: - KeyStore
struct KeyStore {
    static let keyFile: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("ClipLocal")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("key.bin")
    }()

    static func generateKey() -> Data {
        var key = Data(count: 32)
        let result = key.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        if result == errSecSuccess { return key }
        fatalError("Failed to generate encryption key")
    }

    static func loadOrCreateKey() -> Data {
        if let data = try? Data(contentsOf: keyFile) {
            return data
        }
        let newKey = generateKey()
        try? newKey.write(to: keyFile, options: .atomic)
        return newKey
    }
}

// MARK: - Crypto
import CryptoKit

struct CryptoHelper {
    static func encrypt(_ data: Data, key: Data) throws -> Data {
        let symKey = SymmetricKey(data: key)
        let sealedBox = try AES.GCM.seal(data, using: symKey)
        return sealedBox.combined!
    }

    static func decrypt(_ data: Data, key: Data) throws -> Data {
        let symKey = SymmetricKey(data: key)
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: symKey)
    }
}

// MARK: - Models
struct ClipItem: Codable, Identifiable, Hashable {
    /// Stable UUID — never changes, even when the item's date is refreshed after a copy.
    var id: String = UUID().uuidString
    var text: String
    var date: Date
    var isEdited: Bool = false
    var pinned: Bool = false
    var imageData: Data?
    var sourceAppBundleIdentifier: String?
    var isRemote: Bool?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ClipItem, rhs: ClipItem) -> Bool {
        return lhs.id == rhs.id && lhs.text == rhs.text && lhs.isEdited == rhs.isEdited && lhs.pinned == rhs.pinned && lhs.date == rhs.date
    }
}

extension ClipItem {
    /// Custom decoder so existing saved items that predate the stable-id field
    /// get a freshly generated UUID instead of crashing on a missing key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id   = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        text = try c.decode(String.self, forKey: .text)
        date = try c.decode(Date.self,   forKey: .date)
        pinned                    = (try? c.decode(Bool.self,   forKey: .pinned))                    ?? false
        imageData                 =  try? c.decode(Data.self,   forKey: .imageData)
        sourceAppBundleIdentifier =  try? c.decode(String.self, forKey: .sourceAppBundleIdentifier)
        isRemote                  =  try? c.decode(Bool.self,   forKey: .isRemote)
        isEdited                  =  (try? c.decode(Bool.self,   forKey: .isEdited))                 ?? false
    }
}

// MARK: - Shared formatters & caches

/// Reused across all rows — DateFormatter is expensive to construct.
private let sharedDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "d MMM, h:mm a"
    return f
}()

/// Thread-safe cache for NSWorkspace app icons so we never hit disk more than
/// once per bundle identifier during a session.
final class AppIconCache {
    static let shared = AppIconCache()
    /// NSCache is thread-safe — no manual locking needed.
    private let cache = NSCache<NSString, NSImage>()

    func icon(forBundleID bundleID: String?) -> NSImage {
        let key = (bundleID ?? "__finder__") as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let img: NSImage
        if let bid = bundleID,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            img = NSWorkspace.shared.icon(forFile: appURL.path)
        } else {
            img = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        }

        cache.setObject(img, forKey: key)
        return img
    }
}

class ItemTypeCache {
    static let shared = ItemTypeCache()
    private var cache = NSCache<NSString, NSString>()
    
    func invalidate(for id: String) {
        cache.removeObject(forKey: id as NSString)
    }
    
    func type(for item: ClipItem) -> String {
        if let cached = cache.object(forKey: item.id as NSString) {
            return cached as String
        }
        
        let t: String
        if item.imageData != nil { t = "image" }
        else {
            // Clamp type detection to the first 2000 characters to prevent running regex on massive strings
            let rawTxt = item.text.count > 2000 ? String(item.text.prefix(2000)) : item.text
            let txt = rawTxt.trimmingCharacters(in: .whitespacesAndNewlines)
            if txt.hasPrefix("http://") || txt.hasPrefix("https://") || txt.hasPrefix("www.") { t = "link" }
            else {
                let parts = txt.split(separator: "@")
                if parts.count == 2 && parts[1].contains(".") && !txt.contains(" ") { t = "email" }
                else if txt.range(of: "^[0-9 +().-]{5,}$", options: .regularExpression) != nil { t = "number" }
                else if (txt.hasPrefix("/") || txt.hasPrefix("file://")) && !txt.contains("\n") { t = "file" }
                else if txt.hasPrefix("[Image") && txt.hasSuffix("]") { t = "image" }
                else if ["{", "}", "func ", "var ", "let ", "class ", "struct ", "<", ">", ";", "&&", "||", "==", "!=", "=>", "->", "def ", "import ", "const ", "function ", "sudo ", "echo ", "print(", "return ", "#!/bin/", "$ ", "npm ", "brew ", "apt-get", "git ", "docker ", "chmod ", "chown ", "mkdir ", "pkill ", " | ", " > ", " >> "].contains(where: { txt.contains($0) }) || txt.range(of: "^(cat|tail|head|grep|awk|sed|curl|wget|find|ssh|kill)\\s+([-/.~$\"']|\\S+\\.\\S+)", options: [.regularExpression, .caseInsensitive]) != nil { t = "code" }
                else { t = "text" }
            }
        }
        
        cache.setObject(t as NSString, forKey: item.id as NSString)
        return t
    }
}

/// Module-level helper so both ContentView and ClipItemRowView can share
/// the same type-detection logic without duplicating it.
func clipItemType(for item: ClipItem) -> String {
    return ItemTypeCache.shared.type(for: item)
}

enum PrivacyMode: String {
    case session
    case persistent
}

// MARK: - ClipboardManager
class ImagePreviewCache {
    static let shared = ImagePreviewCache()
    private var cache = NSCache<NSString, NSImage>()
    
    func image(for item: ClipItem) -> NSImage? {
        if let cached = cache.object(forKey: item.id as NSString) {
            return cached
        }
        guard let data = item.imageData, let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: item.id as NSString)
        return img
    }
}

struct TypeCount {
    var total: Int = 0
    var pinned: Int = 0
    var unpinned: Int { total - pinned }
}

class ClipboardManager: ObservableObject {
    @Published var history: [ClipItem] = [] { didSet { updateFilteredHistory() } }
    @Published var expandedIdx: Set<String> = []
    @Published var currentSearchText = "" { didSet { updateFilteredHistory() } }
    @Published var activeFilters: Set<String> = [] { didSet { updateFilteredHistory() } }
    @Published var filteredHistory: [ClipItem] = []
    @Published var filterCounts: [String: TypeCount] = [:]
    @Published var resizableMenu: Bool
    @Published var menuHeight: Double
    @Published var pinFlash: Bool = false

    let key = KeyStore.loadOrCreateKey()
    let defaults = UserDefaults.standard
    var lastChangeCount = NSPasteboard.general.changeCount
    /// Serial background queue for encrypt + disk-write so the main thread never blocks.
    private let saveQueue = DispatchQueue(label: "com.aoh.cliplocal.history.save", qos: .utility)

    var mode: PrivacyMode {
        get { PrivacyMode(rawValue: defaults.string(forKey: "mode") ?? "persistent") ?? .persistent }
        set { defaults.set(newValue.rawValue, forKey: "mode") }
    }

    var skipConcealed: Bool {
        get { defaults.object(forKey: "skipConcealed") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "skipConcealed") }
    }

    var maxHistorySize: Int {
        get { defaults.object(forKey: "maxItems") as? Int ?? 200 }
        set { defaults.set(newValue, forKey: "maxItems"); trimHistory() }
    }

    init() {
        self.resizableMenu = UserDefaults.standard.object(forKey: "resizableMenu") as? Bool ?? false
        self.menuHeight = UserDefaults.standard.object(forKey: "menuHeight") as? Double ?? 500.0
        if mode == .persistent { loadHistory() }
    }

    var historyFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("ClipLocal")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.enc")
    }

    func loadHistory() {
        if let dec = try? Data(contentsOf: historyFile) {
            let arr = try? JSONDecoder().decode([ClipItem].self, from: CryptoHelper.decrypt(dec, key: key))
            self.history = arr ?? []
        }
        updateFilteredHistory()
    }

    func saveHistory() {
        // Capture values on the main thread, then encrypt + write in the background.
        let snapshot = history
        let encKey   = key
        let url      = historyFile
        saveQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot),
                  let enc  = try? CryptoHelper.encrypt(data, key: encKey) else { return }
            try? enc.write(to: url, options: .atomic)
        }
    }

    /// Drain any pending background save — call on app quit to avoid data loss.
    func flushPendingSave() {
        saveQueue.sync {}
    }

    func clearHistoryFile() {
        try? FileManager.default.removeItem(at: historyFile)
    }

    func persistIfNeeded() {
        if mode == .persistent { saveHistory() }
    }

    func trimHistory() {
        let max = maxHistorySize
        if history.count > max {
            // Keep pinned items
            let pinned   = history.filter {  $0.pinned }
            let unpinned = history.filter { !$0.pinned }.prefix(Swift.max(0, max - pinned.count))
            history = pinned + Array(unpinned)
            // Sort back by date
            history.sort { $0.date > $1.date }
            persistIfNeeded()  // keep the on-disk file in sync after a trim
        }
    }

    func updateFilteredHistory() {
        var counts = [String: TypeCount]()
        var all = TypeCount()
        var pin = TypeCount()
        
        for item in history {
            let t = clipItemType(for: item)
            var c = counts[t] ?? TypeCount()
            c.total += 1
            all.total += 1
            if item.pinned {
                c.pinned += 1
                all.pinned += 1
                pin.total += 1
                pin.pinned += 1
            }
            counts[t] = c
        }
        counts["all"] = all
        counts["pinned"] = pin
        filterCounts = counts

        var result = history

        if activeFilters.contains("pinned") {
            result = result.filter { $0.pinned }
        } else {
            result = result.filter { !$0.pinned }
        }

        let typeFilters = activeFilters.subtracting(["pinned"])
        if !typeFilters.isEmpty {
            result = result.filter { item in
                let type = clipItemType(for: item)
                return typeFilters.contains(type)
            }
        }

        if !currentSearchText.isEmpty {
            let lower = currentSearchText.lowercased()
            result = result.filter { $0.text.lowercased().contains(lower) }
        }

        filteredHistory = result.sorted {
            if $0.pinned && !$1.pinned { return true }
            if !$0.pinned && $1.pinned { return false }
            return $0.date > $1.date
        }
    }
}

// MARK: - SwiftUI Views
struct ContentView: View {
    @ObservedObject var manager: ClipboardManager
    @State private var copiedItemId: String? = nil
    @State private var dragStartHeight: Double? = nil
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 16))
                TextField("Search Clipboard History", text: $manager.currentSearchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 16))

                Spacer()

                Button(action: {
                    (NSApp.delegate as? AppDelegate)?.showSettingsMenu()
                }) {
                    Image(systemName: "gearshape")
                        .foregroundColor(.blue)
                        .font(.system(size: 18))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color.clear)

            Divider()

            // Filters
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    Button(action: {
                        manager.activeFilters.removeAll()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 11))
                            Text("All")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(manager.activeFilters.isEmpty ? Color.blue : Color.secondary.opacity(0.1))
                        .foregroundColor(manager.activeFilters.isEmpty ? .white : .primary)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.secondary.opacity(0.2), lineWidth: manager.activeFilters.isEmpty ? 0 : 1)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Right-click for mass actions")
                    .contextMenu {
                        let c = manager.filterCounts["all"] ?? TypeCount()
                        
                        Button(action: {
                            for i in 0..<manager.history.count {
                                manager.history[i].pinned = true
                            }
                            manager.saveHistory()
                        }) {
                            Label("Pin All Items (\(c.unpinned))", systemImage: "pin")
                        }
                        
                        Button(action: {
                            for i in 0..<manager.history.count {
                                manager.history[i].pinned = false
                            }
                            manager.saveHistory()
                        }) {
                            Label("Unpin All Items (\(c.pinned))", systemImage: "pin.slash")
                        }
                        
                        Divider()
                        
                        Button(role: .destructive, action: {
                            manager.history.removeAll()
                            manager.saveHistory()
                        }) {
                            Label("Delete All Items (\(c.total))", systemImage: "trash")
                        }
                    }

                    FilterButton(title: nil, systemImage: "pin.fill", filterType: "pinned", manager: manager)
                    FilterButton(title: "Code", systemImage: "chevron.left.forwardslash.chevron.right", filterType: "code", manager: manager)
                    FilterButton(title: "Email", systemImage: "envelope", filterType: "email", manager: manager)
                    FilterButton(title: "Files", systemImage: "doc", filterType: "file", manager: manager)
                    FilterButton(title: "Images", systemImage: "photo", filterType: "image", manager: manager)
                    FilterButton(title: "Links", systemImage: "link", filterType: "link", manager: manager)
                    FilterButton(title: "Numbers", systemImage: "number", filterType: "number", manager: manager)
                    FilterButton(title: "Text", systemImage: "text.alignleft", filterType: "text", manager: manager)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color.clear)

            Divider()

            // List
            List {
                if manager.filteredHistory.isEmpty {
                    Text("— empty —")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                } else if manager.activeFilters.isEmpty && manager.currentSearchText.isEmpty {
                    ForEach(Array(manager.filteredHistory.enumerated()), id: \.element.id) { idx, item in
                        ClipItemRowView(
                            item: item,
                            shortcutIndex: idx < 9 ? idx : nil,
                            copiedItemId: $copiedItemId,
                            manager: manager
                        )
                    }
                } else {
                    ForEach(manager.filteredHistory) { item in
                        ClipItemRowView(
                            item: item,
                            shortcutIndex: nil,
                            copiedItemId: $copiedItemId,
                            manager: manager
                        )
                    }
                }
            }
            .listStyle(.plain)
            .background(Color.clear)
            .scrollContentBackground(colorScheme == .light ? .hidden : .visible)

            if manager.resizableMenu {
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        Spacer()
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if dragStartHeight == nil {
                                    dragStartHeight = manager.menuHeight
                                    if let appDelegate = NSApp.delegate as? AppDelegate {
                                        appDelegate.popover.animates = false
                                    }
                                }
                                if let start = dragStartHeight {
                                    let maxAllowedHeight = Double(NSScreen.main?.visibleFrame.height ?? 1200) - 20
                                    let newHeight = max(300, min(maxAllowedHeight, start + Double(value.translation.height)))
                                    manager.menuHeight = newHeight
                                    if let appDelegate = NSApp.delegate as? AppDelegate {
                                        appDelegate.popover.contentSize = NSSize(width: 450, height: newHeight)
                                    }
                                }
                            }
                            .onEnded { _ in
                                dragStartHeight = nil
                                manager.defaults.set(manager.menuHeight, forKey: "menuHeight")
                                if let appDelegate = NSApp.delegate as? AppDelegate {
                                    appDelegate.popover.animates = true
                                }
                            }
                    )
                    .onHover { isHovering in
                        if isHovering {
                            NSCursor.resizeUpDown.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .frame(width: 450, height: CGFloat(manager.menuHeight))
        .background(Color.clear)
        .onDisappear {
            // Clear stale copy-button animation so it never shows on next open.
            copiedItemId = nil
        }
    }

    // MARK: - Helpers
}

// MARK: - ClipItemRowView
/// A self-contained row view for each clipboard item.
/// Keeping hover state and copy-button animation local here means SwiftUI
/// only needs to re-render the single hovered row instead of the whole list.
struct ClipItemRowView: View {
    let item: ClipItem
    let shortcutIndex: Int?
    @Binding var copiedItemId: String?
    @ObservedObject var manager: ClipboardManager

    /// Local hover state — changes here never propagate up to ContentView.
    @State private var isHovered = false
    @State private var lastClickTime = Date.distantPast
    
    // Edit state
    @State private var isEditing = false
    @State private var editedText = ""

    // MARK: Memoised helpers (computed once per render, not on every sub-view)
    private var itemType: String { clipItemType(for: item) }

    private var iconSystemName: String {
        switch itemType {
        case "code": return "chevron.left.forwardslash.chevron.right"
        case "email": return "envelope"
        case "file": return "doc"
        case "image": return "photo"
        case "link": return "link"
        case "number": return "number"
        default: return "text.alignleft"
        }
    }

    private var typeLabel: String {
        switch itemType {
        case "code": return "Code"
        case "email": return "Email"
        case "file":
            let ext = (item.text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).pathExtension.uppercased()
            return ext.isEmpty ? "File" : "\(ext) file"
        case "image":
            let ext = (item.text.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).pathExtension.uppercased()
            return ext.isEmpty ? "PNG image" : "\(ext) image"
        case "link": return "Link"
        case "number": return "Number"
        default: return "Text"
        }
    }

    private var snippet: String {
        let maxChars = 500
        let txt = item.text.count > maxChars ? String(item.text.prefix(maxChars)) + "…" : item.text
        return txt
            .replacingOccurrences(of: "\n", with: " ↵ ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var formattedDate: String {
        sharedDateFormatter.string(from: item.date)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if let nsImage = ImagePreviewCache.shared.image(for: item) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: iconSystemName)
                    .font(.system(size: 16, weight: .light))
                    .foregroundColor(.secondary)
                    .frame(width: 32)
            }

            VStack(alignment: .leading, spacing: 6) {
                if snippet != "[Image]" {
                    Text(snippet)
                        .lineLimit(manager.expandedIdx.contains(item.id) ? 5 : 1)
                        .truncationMode(.tail)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                }

                if manager.expandedIdx.contains(item.id), let nsImage = ImagePreviewCache.shared.image(for: item) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 200, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(.vertical, 4)
                }

                HStack(spacing: 4) {
                    // Icon is served from cache — no disk I/O on hot path
                    let appIcon = AppIconCache.shared.icon(forBundleID: item.sourceAppBundleIdentifier)
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 12, height: 12)
                        .clipShape(Circle())

                    if let nsImage = ImagePreviewCache.shared.image(for: item) {
                        Text("\(typeLabel) · \(Int(nsImage.size.width)) × \(Int(nsImage.size.height))")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else {
                        Text(typeLabel)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text(formattedDate)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    if item.isRemote == true {
                        Image(systemName: "macbook.and.iphone")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    if item.isEdited {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 8)

            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .rotationEffect(Angle(degrees: 45))
                    .padding(.trailing, 4)
            } else if let sIdx = shortcutIndex {
                Text("⌘\(sIdx + 1)")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                    .padding(.trailing, 2)
            }

            Button(action: { copyItem() }) {
                Image(systemName: copiedItemId == item.id ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 16))
                    .foregroundColor(copiedItemId == item.id ? .white : Color.primary.opacity(0.6))
                    .frame(width: 36, height: 36)
                    .background(copiedItemId == item.id ? Color.green : Color.secondary.opacity(0.1))
                    .clipShape(Circle())
                    .scaleEffect(copiedItemId == item.id ? 0.85 : 1.0)
                    .shadow(color: copiedItemId == item.id ? Color.green.opacity(0.5) : Color.clear,
                            radius: copiedItemId == item.id ? 4 : 0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: copiedItemId)
            }
            .buttonStyle(PlainButtonStyle())
            .background(
                Group {
                    if let sIdx = shortcutIndex {
                        let keyEq = KeyEquivalent(Character(String(sIdx + 1)))
                        Button("") { copyItem() }
                            .keyboardShortcut(keyEq, modifiers: .command)
                            .opacity(0)
                    }
                }
            )
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            let now = Date()
            if now.timeIntervalSince(lastClickTime) < 0.3 {
                copyItem()
            } else {
                if manager.expandedIdx.contains(item.id) {
                    manager.expandedIdx.remove(item.id)
                } else {
                    manager.expandedIdx.insert(item.id)
                }
            }
            lastClickTime = now
        }
        .onHover { hovering in
            // Only this row re-renders — ContentView is untouched
            isHovered = hovering
        }
        .listRowBackground(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
        .contextMenu {
            Button(action: {
                editedText = item.text
                isEditing = true
            }) {
                Label("Edit", systemImage: "square.and.pencil")
            }
        }
        .sheet(isPresented: $isEditing) {
            VStack(alignment: .leading) {
                Text("Edit Clip")
                    .font(.headline)
                    .padding(.bottom, 4)
                TextEditor(text: $editedText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 300, minHeight: 150)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                HStack {
                    Spacer()
                    Button("Cancel") { isEditing = false }
                    Button("Save") {
                        if let idx = manager.history.firstIndex(where: { $0.id == item.id }) {
                            if editedText.isEmpty {
                                manager.history.remove(at: idx)
                                ItemTypeCache.shared.invalidate(for: item.id)
                                manager.saveHistory()
                            } else if manager.history[idx].text != editedText {
                                manager.history[idx].text = editedText
                                manager.history[idx].isEdited = true
                                ItemTypeCache.shared.invalidate(for: item.id)
                                manager.saveHistory()
                            }
                        }
                        isEditing = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 400, height: 250)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { deleteItem() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { togglePin() } label: {
                Label(item.pinned ? "Unpin" : "Pin",
                      systemImage: item.pinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
    }

    // MARK: - Row actions
    private func copyItem() {
        let pb = NSPasteboard.general
        pb.clearContents()

        if let data = item.imageData, let img = NSImage(data: data) {
            pb.writeObjects([img])
        } else if item.text.hasPrefix("file://") {
            let path = String(item.text.dropFirst(7))
            pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
        } else {
            pb.setString(item.text, forType: .string)
        }

        manager.lastChangeCount = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        }

        withAnimation { copiedItemId = item.id }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            (NSApp.delegate as? AppDelegate)?.closePopover()
            (NSApp.delegate as? AppDelegate)?.showPreview(item.text)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let idx = manager.history.firstIndex(where: { $0.id == item.id }) {
                    var updated = item
                    updated.date = Date()
                    manager.history.remove(at: idx)
                    manager.history.insert(updated, at: 0)
                    manager.history.sort {
                        if $0.pinned == $1.pinned { return $0.date > $1.date }
                        return $0.pinned && !$1.pinned
                    }
                    manager.persistIfNeeded()
                }
                if copiedItemId == item.id { copiedItemId = nil }
            }
        }
    }

    private func togglePin() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if let idx = manager.history.firstIndex(where: { $0.id == item.id }) {
                withAnimation {
                    manager.history[idx].pinned.toggle()
                    let wasPinned = manager.history[idx].pinned
                    manager.history.sort {
                        if $0.pinned == $1.pinned { return $0.date > $1.date }
                        return $0.pinned && !$1.pinned
                    }
                    manager.persistIfNeeded()
                    if wasPinned {
                        manager.pinFlash = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            manager.pinFlash = false
                        }
                    }
                }
            }
        }
    }

    private func deleteItem() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if let idx = manager.history.firstIndex(where: { $0.id == item.id }) {
                manager.history.remove(at: idx)
                manager.persistIfNeeded()
            }
        }
    }
}

struct FilterButton: View {
    let title: String?
    let systemImage: String
    let filterType: String
    @ObservedObject var manager: ClipboardManager

    var isSelected: Bool {
        manager.activeFilters.contains(filterType)
    }
    
    var isFlashing: Bool {
        filterType == "pinned" && manager.pinFlash
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
                    .font(.system(size: 11))
                if let title = title, !title.isEmpty {
                    Text(title)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isSelected ? Color.blue : (isFlashing ? Color.orange.opacity(0.9) : Color.secondary.opacity(0.1)))
            .foregroundColor(isSelected || isFlashing ? .white : .primary)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isFlashing ? Color.orange : Color.secondary.opacity(0.2), lineWidth: (isSelected || isFlashing) ? 0 : 1)
            )
            .scaleEffect(isFlashing ? 1.15 : 1.0)
            .shadow(color: isFlashing ? Color.orange.opacity(0.6) : Color.clear, radius: isFlashing ? 4 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isFlashing)
        }
        .buttonStyle(PlainButtonStyle())
        .help("Right-click for mass actions")
        .contextMenu {
            let label = title ?? (filterType == "pinned" ? "Pinned" : "Items")
            let c = manager.filterCounts[filterType] ?? TypeCount()
            
            Button(action: {
                for i in 0..<manager.history.count {
                    if filterType == "pinned" {
                        if manager.history[i].pinned { manager.history[i].pinned = true }
                    } else if clipItemType(for: manager.history[i]) == filterType {
                        manager.history[i].pinned = true
                    }
                }
                manager.saveHistory()
            }) {
                Label("Pin All \(label) (\(c.unpinned))", systemImage: "pin")
            }
            
            Button(action: {
                for i in 0..<manager.history.count {
                    if filterType == "pinned" {
                        manager.history[i].pinned = false
                    } else if clipItemType(for: manager.history[i]) == filterType {
                        manager.history[i].pinned = false
                    }
                }
                manager.saveHistory()
            }) {
                Label("Unpin All \(label) (\(c.pinned))", systemImage: "pin.slash")
            }
            
            Divider()
            
            Button(role: .destructive, action: {
                if filterType == "pinned" {
                    manager.history.removeAll { $0.pinned }
                } else {
                    manager.history.removeAll { clipItemType(for: $0) == filterType }
                }
                manager.saveHistory()
            }) {
                Label("Delete All \(label) (\(c.total))", systemImage: "trash")
            }
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var timer: Timer?
    var previewWindow: NSWindow?
    let clipboardManager = ClipboardManager()
    let defaults = UserDefaults.standard
    var aboutWindow: NSWindow?
    var settingsMenu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if defaults.object(forKey: "hasLaunchedBefore") == nil {
            defaults.set(true, forKey: "hasLaunchedBefore")
            try? SMAppService.mainApp.register()
        }

        NSApp.setActivationPolicy(.accessory)

        let contentView = ContentView(manager: clipboardManager)
        popover = NSPopover()
        popover.contentSize = NSSize(width: 450, height: clipboardManager.menuHeight)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: contentView)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            let img = NSImage(systemSymbolName: "paperclip.circle", accessibilityDescription: "ClipLocal")
            img?.isTemplate = true
            btn.image = img
            btn.action = #selector(togglePopover(_:))
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        setupMainMenu()
        buildSettingsMenu()

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
        RunLoop.main.add(timer!, forMode: .common)

        if !defaults.bool(forKey: "hideAbout") { showAbout(onLaunch: true) }
        checkForUpdates(silentIfCurrent: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Wait for any in-flight background save to finish before the process exits.
        clipboardManager.flushPendingSave()
    }

    @objc func togglePopover(_ sender: AnyObject?) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp || (event.type == .leftMouseUp && event.modifierFlags.contains(.control)) {
            showSettingsMenu()
            return
        }

        if popover.isShown {
            closePopover()
        } else {
            showPopover(sender)
        }
    }

    func showPopover(_ sender: AnyObject?) {
        if let btn = statusItem.button {
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func closePopover() {
        popover.performClose(nil)
    }

    func showSettingsMenu() {
        buildSettingsMenu() // Refresh states
        settingsMenu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func setupMainMenu() {
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        
        editMenuItem.submenu = editMenu
        NSApp.mainMenu = mainMenu
    }

    func buildSettingsMenu() {
        let menu = NSMenu()

        func icon(_ name: String) -> NSImage? {
            let i = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            i?.isTemplate = true
            return i
        }

        let totalCount = clipboardManager.history.count
        let clear = NSMenuItem(title: "Clear History (\(totalCount))", action: #selector(clearHistory), keyEquivalent: "")
        clear.image = icon("trash")
        clear.target = self
        menu.addItem(clear)
        
        let pinnedCount = clipboardManager.filterCounts["pinned"]?.total ?? 0
        let unpin = NSMenuItem(title: "Unpin All (\(pinnedCount))", action: #selector(unpinAll), keyEquivalent: "")
        unpin.image = icon("pin.slash")
        unpin.target = self
        menu.addItem(unpin)

        menu.addItem(.separator())

        let privacy = NSMenuItem(title: "History Storage", action: nil, keyEquivalent: "")
        privacy.image = icon("lock.shield")
        let psub = NSMenu()

        let sessionItem = NSMenuItem(title: "Session-only (wiped on quit)", action: #selector(setSessionMode), keyEquivalent: "")
        sessionItem.state = clipboardManager.mode == .session ? .on : .off
        sessionItem.image = icon("lock")
        sessionItem.target = self

        let persistItem = NSMenuItem(title: "Persistent (kept on quit)", action: #selector(setPersistentMode), keyEquivalent: "")
        persistItem.state = clipboardManager.mode == .persistent ? .on : .off
        persistItem.image = icon("externaldrive.fill")
        persistItem.target = self

        psub.addItem(sessionItem)
        psub.addItem(persistItem)
        privacy.submenu = psub
        menu.addItem(privacy)

        let maxItems = NSMenuItem(title: "Keep up to...", action: nil, keyEquivalent: "")
        maxItems.image = icon("list.number")
        let msub = NSMenu()
        let limits = [50, 100, 200, 500, 1000]
        for limit in limits {
            let item = NSMenuItem(title: "\(limit) Items", action: #selector(setMaxItems(_:)), keyEquivalent: "")
            item.state = clipboardManager.maxHistorySize == limit ? .on : .off
            item.tag = limit
            item.target = self
            msub.addItem(item)
        }
        maxItems.submenu = msub
        menu.addItem(maxItems)

        let concealItem = NSMenuItem(title: "Skip password-manager copies", action: #selector(toggleConcealed), keyEquivalent: "")
        concealItem.state = clipboardManager.skipConcealed ? .on : .off
        concealItem.image = icon("eye.slash")
        concealItem.target = self
        menu.addItem(concealItem)

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunch), keyEquivalent: "")
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        launchItem.image = icon("macwindow")
        launchItem.target = self
        menu.addItem(launchItem)

        let resizeItem = NSMenuItem(title: "Resizable Menu", action: #selector(toggleResizableMenu), keyEquivalent: "")
        resizeItem.state = clipboardManager.resizableMenu ? .on : .off
        resizeItem.image = icon("arrow.up.and.down")
        resizeItem.target = self
        menu.addItem(resizeItem)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About ClipLocal", action: #selector(showAboutMenu), keyEquivalent: "")
        about.image = icon("info.circle")
        about.target = self
        menu.addItem(about)

        let update = NSMenuItem(title: "Check for Updates...", action: #selector(manualUpdateCheck), keyEquivalent: "")
        update.image = icon("arrow.triangle.2.circlepath")
        update.target = self
        menu.addItem(update)

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.image = icon("power")
        quit.target = self
        menu.addItem(quit)

        settingsMenu = menu
    }

    @objc func clearHistory() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        clipboardManager.history.removeAll()
        clipboardManager.clearHistoryFile()
    }
    
    @objc func unpinAll() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        var didChange = false
        for i in 0..<clipboardManager.history.count {
            if clipboardManager.history[i].pinned {
                clipboardManager.history[i].pinned = false
                didChange = true
            }
        }
        if didChange {
            clipboardManager.history.sort { $0.date > $1.date }
            clipboardManager.persistIfNeeded()
        }
    }

    @objc func setSessionMode() {
        clipboardManager.mode = .session
        clipboardManager.clearHistoryFile()
    }

    @objc func setPersistentMode() {
        clipboardManager.mode = .persistent
        clipboardManager.saveHistory()
    }

    @objc func toggleConcealed() { clipboardManager.skipConcealed.toggle() }


    @objc func setMaxItems(_ sender: NSMenuItem) {
        let newLimit = sender.tag
        let currentCount = clipboardManager.history.count
        if currentCount > newLimit {
            let toDelete = currentCount - newLimit
            let alert = NSAlert()
            alert.messageText = "Trim Clipboard History?"
            alert.informativeText = "Reducing to \(newLimit) items will permanently delete \(toDelete) older entr\(toDelete == 1 ? "y" : "ies"). This cannot be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Trim History")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        clipboardManager.maxHistorySize = newLimit
    }

    @objc func toggleLaunch() {
        let service = SMAppService.mainApp
        if service.status == .enabled {
            try? service.unregister()
        } else {
            try? service.register()
        }
    }

    @objc func toggleResizableMenu() {
        clipboardManager.resizableMenu.toggle()
        clipboardManager.defaults.set(clipboardManager.resizableMenu, forKey: "resizableMenu")
    }

    @objc func manualUpdateCheck() { checkForUpdates(silentIfCurrent: false) }
    @objc func quitApp() { NSApp.terminate(nil) }

    // MARK: - About window (privacy-first splash)

    @objc func showAboutMenu() { showAbout(onLaunch: false) }

    func showAbout(onLaunch: Bool = false) {
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
        icon.image = NSImage(systemSymbolName: "paperclip.circle", accessibilityDescription: nil)?
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

        let features = [
            ("lock.shield", "100% On-Device & Private", "Your clipboard data never leaves your Mac. No cloud, no tracking, no accounts."),
            ("key", "Skips Secrets", "By default, passwords copied from 1Password, Bitwarden, etc., are completely ignored."),
            ("eye.slash", "No Analytics", "Zero telemetry. The app only connects to GitHub manually when you check for updates."),
            ("externaldrive.fill", "Encrypted Storage", "In Persistent mode, your history is encrypted (AES-GCM) on disk. Only your Mac account can read it."),
            ("chevron.left.forwardslash.chevron.right", "Free & Open Source", "ClipLocal is completely free and open source. Check out the code on GitHub.")
        ]

        let bodyWidth = width - 80
        let textWidth = bodyWidth - 44
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        let textFont = NSFont.systemFont(ofSize: 12.5)
        let titleFont = NSFont.systemFont(ofSize: 13.5, weight: .bold)

        var featureHeights: [CGFloat] = []
        var totalFeaturesHeight: CGFloat = 0
        for f in features {
            let attr = NSAttributedString(string: f.2, attributes: [
                .font: textFont,
                .paragraphStyle: para
            ])
            let measured = attr.boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            let h = ceil(measured.height) + 24 // title height + spacing
            featureHeights.append(h)
            totalFeaturesHeight += h + 20 // item spacing
        }
        totalFeaturesHeight -= 20 // remove last spacing

        let textTop = (height - 210) - 24
        let bottomSpaceNeeded: CGFloat = 160
        let newHeight = (height - textTop) + totalFeaturesHeight + bottomSpaceNeeded
        let finalHeight = max(height, newHeight)

        let oldFrame = win.frame
        win.setFrame(NSRect(x: oldFrame.minX, y: oldFrame.maxY - finalHeight, width: width, height: finalHeight), display: true)
        bg.frame = NSRect(x: 0, y: 0, width: width, height: finalHeight)

        icon.frame.origin.y = finalHeight - 120
        name.frame.origin.y = finalHeight - 164
        version.frame.origin.y = finalHeight - 186
        tagline.frame.origin.y = finalHeight - 210
        let newTextTop = (finalHeight - 210) - 24

        var currentY = newTextTop
        for (i, f) in features.enumerated() {
            let itemH = featureHeights[i]
            let itemY = currentY - itemH

            let iconSize: CGFloat = 32
            let iconY = itemY + (itemH - iconSize) / 2
            let iconView = NSImageView(frame: NSRect(x: 40, y: iconY, width: iconSize, height: iconSize))
            let iconCfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            iconView.image = NSImage(systemSymbolName: f.0, accessibilityDescription: nil)?
                .withSymbolConfiguration(iconCfg)
            iconView.contentTintColor = NSColor.controlAccentColor
            bg.addSubview(iconView)

            let titleLabel = NSTextField(labelWithString: f.1)
            titleLabel.frame = NSRect(x: 84, y: itemY + itemH - 22, width: textWidth, height: 18)
            titleLabel.font = titleFont
            titleLabel.textColor = .labelColor
            titleLabel.isEditable = false
            titleLabel.drawsBackground = false
            titleLabel.isBordered = false
            bg.addSubview(titleLabel)

            let attr = NSAttributedString(string: f.2, attributes: [
                .font: textFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: para
            ])
            let descLabel = NSTextField(labelWithAttributedString: attr)
            descLabel.frame = NSRect(x: 84, y: itemY, width: textWidth, height: itemH - 24)
            descLabel.lineBreakMode = .byWordWrapping
            descLabel.maximumNumberOfLines = 0
            descLabel.isEditable = false
            descLabel.drawsBackground = false
            descLabel.isBordered = false
            bg.addSubview(descLabel)

            currentY = itemY - 20
        }

        let credit = NSTextField(labelWithString: "Built by Arun Thomas")
        credit.frame = NSRect(x: 0, y: currentY - 34, width: width, height: 18)
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
        dontShow.state = defaults.object(forKey: "hideAbout") == nil ? .on : (defaults.bool(forKey: "hideAbout") ? .on : .off)
        if defaults.object(forKey: "hideAbout") == nil {
            defaults.set(true, forKey: "hideAbout")
        }
        bg.addSubview(dontShow)

        let buttonsY = dontShow.frame.minY - 48
        
        let contactW: CGFloat = 100
        let gitW: CGFloat = 100
        let closeW: CGFloat = 120
        let spacing: CGFloat = 16
        let totalW = contactW + gitW + closeW + (2 * spacing)
        let startX = (width - totalW) / 2
        
        let contact = NSButton(title: "Contact", target: self, action: #selector(contactDeveloper))
        contact.frame = NSRect(x: startX, y: buttonsY, width: contactW, height: 32)
        contact.isBordered = false
        contact.wantsLayer = true
        contact.layer?.backgroundColor = NSColor.white.cgColor
        contact.layer?.cornerRadius = 16
        contact.layer?.masksToBounds = true
        contact.attributedTitle = NSAttributedString(string: "Contact", attributes: [
            .foregroundColor: NSColor.black,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ])
        bg.addSubview(contact)

        let github = NSButton(title: "GitHub", target: self, action: #selector(openGitHub))
        github.frame = NSRect(x: startX + contactW + spacing, y: buttonsY, width: gitW, height: 32)
        github.isBordered = false
        github.wantsLayer = true
        github.layer?.backgroundColor = NSColor.black.cgColor
        github.layer?.cornerRadius = 16
        github.layer?.masksToBounds = true
        github.attributedTitle = NSAttributedString(string: "GitHub", attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ])
        bg.addSubview(github)

        let close = NSButton(title: "Get Started", target: self, action: #selector(closeAbout))
        close.frame = NSRect(x: startX + contactW + spacing + gitW + spacing, y: buttonsY, width: closeW, height: 32)
        close.isBordered = false
        close.wantsLayer = true
        close.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        close.layer?.cornerRadius = 16
        close.layer?.masksToBounds = true
        close.keyEquivalent = "\r"
        close.attributedTitle = NSAttributedString(string: "Get Started", attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ])
        bg.addSubview(close)

        win.contentView = bg
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.aboutWindow = win
    }

    @objc func contactDeveloper() {
        let subject = "ClipLocal feedback"
        let encoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        if let url = URL(string: "mailto:arunthomas04042001@gmail.com?subject=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openGitHub() {
        if let url = URL(string: "https://github.com/arunofhyd/ClipLocal") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func toggleHideAbout(_ sender: NSButton) {
        defaults.set(sender.state == .on, forKey: "hideAbout")
    }

    @objc func closeAbout() {
        aboutWindow?.close()
        aboutWindow = nil
        // Only open the popover if it isn’t already visible — avoids closing it instead of opening.
        if !popover.isShown {
            showPopover(statusItem?.button)
        }
    }

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
        let sourceApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let first = urls.first {
            newText = "file://" + first.path
        } else if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let img = images.first {
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                newImage = png
                var extractedName = "[Image]"
                if let html = pb.string(forType: NSPasteboard.PasteboardType("public.html")) {
                    if let range = html.range(of: "alt=\"([^\"]+)\"", options: .regularExpression) {
                        let alt = String(html[range]).replacingOccurrences(of: "alt=\"", with: "").replacingOccurrences(of: "\"", with: "")
                        if !alt.isEmpty { extractedName = alt }
                    } else if let range = html.range(of: "src=\"([^\"]+)\"", options: .regularExpression) {
                        let src = String(html[range]).replacingOccurrences(of: "src=\"", with: "").replacingOccurrences(of: "\"", with: "")
                        if let url = URL(string: src) {
                            let filename = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
                            if !filename.isEmpty { extractedName = filename }
                        }
                    }
                }
                
                if extractedName == "[Image]" {
                    let possibleName = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let name = possibleName, !name.isEmpty { extractedName = name }
                }
                newText = extractedName
            }
        } else if let str = pb.string(forType: .string) {
            let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return }
            newText = str
        }

        guard let text = newText else { return }

        let isRemote = pb.types?.contains(NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")) ?? false

        // Needs to be run on main thread since it updates @Published history
        DispatchQueue.main.async {
            if let idx = self.clipboardManager.history.firstIndex(where: { $0.text == text && $0.imageData == newImage }) {
                let pinned = self.clipboardManager.history[idx].pinned
                self.clipboardManager.history.remove(at: idx)
                let newItem = ClipItem(text: text, date: Date(), pinned: pinned, imageData: newImage, sourceAppBundleIdentifier: sourceApp, isRemote: isRemote)
                self.clipboardManager.history.insert(newItem, at: 0)
            } else {
                let newItem = ClipItem(text: text, date: Date(), pinned: false, imageData: newImage, sourceAppBundleIdentifier: sourceApp, isRemote: isRemote)
                self.clipboardManager.history.insert(newItem, at: 0)
                self.showPreview(text)
            }
            
            // Auto-cleanup: Apple Universal Clipboard destroys old Handoff file promises when a new item is copied.
            // Remove any old remote files so they don't clutter the UI with dead links.
            self.clipboardManager.history.removeAll {
                ($0.isRemote == true) && $0.text.hasPrefix("file://") && $0.id != self.clipboardManager.history.first?.id
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

        let mask = NSImage(size: container.bounds.size, flipped: false) { rect in
            NSColor.black.set()
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            return true
        }
        container.maskImage = mask

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
                tv.autoresizingMask = [.width]
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 340, height: 130))
                scroll.hasVerticalScroller = true; scroll.drawsBackground = false
                scroll.wantsLayer = true
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
    
    func popoverDidClose(_ notification: Notification) {
        clipboardManager.expandedIdx.removeAll()
    }
}

// MARK: - App Main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
