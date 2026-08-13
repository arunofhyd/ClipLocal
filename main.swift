import Cocoa
import SwiftUI
import ServiceManagement
import Combine
import AVFoundation
import QuickLookThumbnailing
import Security

// ============================================================
//  ClipLocal — 100% on-device clipboard history, no third parties
// ============================================================

let appVersion = "1.3.5"
let updateCheckURL = "https://raw.githubusercontent.com/arunofhyd/ClipLocal/main/version.json"
let downloadPageURL = "https://cliplocal.vercel.app/#install"

// MARK: - KeyStore
struct KeyStore {
    private static let service = "com.aoh.cliplocal"
    private static let account = "clipboardKey"

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

    /// Primary: macOS Keychain. Fallback: key.bin on disk.
    /// Migrates existing users' key.bin into Keychain seamlessly.
    /// New users get Keychain-only storage with no key.bin on disk.
    static func loadOrCreateKey() -> Data {
        // 1. Try loading key from macOS Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            // Only sync key.bin if user was an existing migrated user (file exists)
            // For brand-new users, key remains strictly isolated in Keychain!
            if FileManager.default.fileExists(atPath: keyFile.path) {
                syncKeyFile(with: data)
            }
            return data
        }

        // 2. If key doesn't exist in Keychain yet, migrate existing key.bin or generate a new one
        if status == errSecItemNotFound {
            let keyToUse: Data
            let isMigration: Bool

            if let existingFileKey = try? Data(contentsOf: keyFile), existingFileKey.count == 32 {
                keyToUse = existingFileKey // Migration for existing users
                isMigration = true
            } else {
                keyToUse = generateKey()   // Fresh key for new users (Keychain only)
                isMigration = false
            }

            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: keyToUse,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                if isMigration { syncKeyFile(with: keyToUse) }
                return keyToUse
            }

            // Fallback: If Keychain add failed, write to key.bin so app still functions
            syncKeyFile(with: keyToUse)
            return keyToUse
        }

        // 3. Fallback to local file key.bin if Keychain is unavailable or restricted
        return loadOrCreateFallbackFileKey()
    }

    /// Helper to ensure `key.bin` backup is always in sync with Keychain key
    private static func syncKeyFile(with key: Data) {
        if let existing = try? Data(contentsOf: keyFile), existing == key {
            return
        }
        try? key.write(to: keyFile, options: .atomic)
    }

    private static func loadOrCreateFallbackFileKey() -> Data {
        if let data = try? Data(contentsOf: keyFile), data.count == 32 {
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

// MARK: - External Large Payload Storage
struct LargePayloadStore {
    private static let cache = NSCache<NSString, NSString>()

    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("ClipLocal/payloads")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func savePayload(id: String, text: String, key: Data) -> String {
        let fileName = "\(id).payload"
        let fileURL = dir.appendingPathComponent(fileName)
        if let data = text.data(using: .utf8),
           let enc = try? CryptoHelper.encrypt(data, key: key) {
            try? enc.write(to: fileURL, options: .atomic)
        }
        cache.setObject(text as NSString, forKey: fileName as NSString)
        return fileName
    }

    static func loadPayload(fileName: String, key: Data) -> String? {
        if let cached = cache.object(forKey: fileName as NSString) {
            return cached as String
        }
        let fileURL = dir.appendingPathComponent(fileName)
        guard let enc = try? Data(contentsOf: fileURL),
              let dec = try? CryptoHelper.decrypt(enc, key: key),
              let str = String(data: dec, encoding: .utf8) else { return nil }
        cache.setObject(str as NSString, forKey: fileName as NSString)
        return str
    }

    static func deletePayload(fileName: String?) {
        guard let pf = fileName else { return }
        cache.removeObject(forKey: pf as NSString)
        let fileURL = dir.appendingPathComponent(pf)
        try? FileManager.default.removeItem(at: fileURL)
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
    var payloadFileName: String?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ClipItem, rhs: ClipItem) -> Bool {
        return lhs.id == rhs.id && lhs.text == rhs.text && lhs.isEdited == rhs.isEdited && lhs.pinned == rhs.pinned && lhs.date == rhs.date && lhs.payloadFileName == rhs.payloadFileName
    }

    func fullText(key: Data) -> String {
        if let pf = payloadFileName, let full = LargePayloadStore.loadPayload(fileName: pf, key: key) {
            return full
        }
        return text
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
        payloadFileName           =  try? c.decode(String.self, forKey: .payloadFileName)
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

// MARK: - Color Parser
struct ColorParser {
    static func parse(_ text: String) -> NSColor? {
        var str = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.count > 60 || str.isEmpty { return nil }
        
        // Strip common code wrappers/prefixes/suffixes: quotes, semicolons, css properties
        str = str.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`;,"))
        let lower = str.lowercased()
        if lower.hasPrefix("color:") {
            str = String(str.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if lower.hasPrefix("background-color:") {
            str = String(str.dropFirst(17)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if lower.hasPrefix("background:") {
            str = String(str.dropFirst(11)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        str = str.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`;,"))
        
        // Handle 0x prefix if present
        if str.lowercased().hasPrefix("0x") {
            str = "#" + String(str.dropFirst(2))
        }
        
        // 1. HEX format: #RGB, #RGBA, #RRGGBB, #RRGGBBAA
        // Must start with '#' (or 0x / CSS property prefix) to prevent false positives on random alphanumeric strings like '24A402'
        let isHexWithHash = str.hasPrefix("#")
        let cleanHex = isHexWithHash ? String(str.dropFirst()) : str
        
        let hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        if isHexWithHash && !cleanHex.isEmpty && cleanHex.unicodeScalars.allSatisfy({ hexCharacterSet.contains($0) }) {
            var fullHex = cleanHex
            if cleanHex.count == 3 {
                fullHex = cleanHex.map { "\($0)\($0)" }.joined()
            } else if cleanHex.count == 4 {
                fullHex = cleanHex.map { "\($0)\($0)" }.joined()
            }
            
            if let val = UInt64(fullHex, radix: 16) {
                let r, g, b, a: CGFloat
                if fullHex.count == 6 {
                    r = CGFloat((val >> 16) & 0xFF) / 255.0
                    g = CGFloat((val >> 8) & 0xFF) / 255.0
                    b = CGFloat(val & 0xFF) / 255.0
                    a = 1.0
                    return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
                } else if fullHex.count == 8 {
                    r = CGFloat((val >> 24) & 0xFF) / 255.0
                    g = CGFloat((val >> 16) & 0xFF) / 255.0
                    b = CGFloat((val >> 8) & 0xFF) / 255.0
                    a = CGFloat(val & 0xFF) / 255.0
                    return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
                }
            }
        }
        
        // 2. RGB / RGBA format: rgb(r, g, b) or rgba(r, g, b, a)
        let rgbaPattern = "^rgba?\\(\\s*(\\d{1,3}%?)\\s*,\\s*(\\d{1,3}%?)\\s*,\\s*(\\d{1,3}%?)(?:\\s*,\\s*([\\d.]+))?\\s*\\)$"
        if let regex = try? NSRegularExpression(pattern: rgbaPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: str, range: NSRange(location: 0, length: str.utf16.count)) {
            func parseVal(_ range: NSRange) -> CGFloat {
                let s = (str as NSString).substring(with: range)
                if s.hasSuffix("%") {
                    let v = Double(s.dropLast()) ?? 0
                    return CGFloat(v / 100.0)
                }
                let v = Double(s) ?? 0
                return CGFloat(v / 255.0)
            }
            let r = parseVal(match.range(at: 1))
            let g = parseVal(match.range(at: 2))
            let b = parseVal(match.range(at: 3))
            var a: CGFloat = 1.0
            if match.range(at: 4).location != NSNotFound {
                let aStr = (str as NSString).substring(with: match.range(at: 4))
                a = CGFloat(Double(aStr) ?? 1.0)
            }
            return NSColor(srgbRed: min(1.0, max(0.0, r)), green: min(1.0, max(0.0, g)), blue: min(1.0, max(0.0, b)), alpha: min(1.0, max(0.0, a)))
        }
        
        // 3. HSL / HSLA format: hsl(h, s%, l%) or hsla(h, s%, l%, a)
        let hslaPattern = "^hsla?\\(\\s*(\\d{1,3})\\s*,\\s*(\\d{1,3})%\\s*,\\s*(\\d{1,3})%(?:\\s*,\\s*([\\d.]+))?\\s*\\)$"
        if let regex = try? NSRegularExpression(pattern: hslaPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: str, range: NSRange(location: 0, length: str.utf16.count)) {
            let hStr = (str as NSString).substring(with: match.range(at: 1))
            let sStr = (str as NSString).substring(with: match.range(at: 2))
            let lStr = (str as NSString).substring(with: match.range(at: 3))
            
            let h = (CGFloat(Double(hStr) ?? 0).truncatingRemainder(dividingBy: 360)) / 360.0
            let s = CGFloat(Double(sStr) ?? 0) / 100.0
            let l = CGFloat(Double(lStr) ?? 0) / 100.0
            var a: CGFloat = 1.0
            if match.range(at: 4).location != NSNotFound {
                let aStr = (str as NSString).substring(with: match.range(at: 4))
                a = CGFloat(Double(aStr) ?? 1.0)
            }
            
            let (r, g, b) = hslToRgb(h: h, s: s, l: l)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
        
        return nil
    }
    
    private static func hslToRgb(h: CGFloat, s: CGFloat, l: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        if s == 0 {
            return (l, l, l)
        }
        let qVal = l < 0.5 ? l * (1 + s) : l + s - l * s
        let pVal = 2 * l - qVal
        
        func hueToRgb(_ tParam: CGFloat) -> CGFloat {
            var t = tParam
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1/6 { return pVal + (qVal - pVal) * 6 * t }
            if t < 1/2 { return qVal }
            if t < 2/3 { return pVal + (qVal - pVal) * (2/3 - t) * 6 }
            return pVal
        }
        
        return (hueToRgb(h + 1/3), hueToRgb(h), hueToRgb(h - 1/3))
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
            // Clamp type detection to prefix(2000) directly without computing total string count
            let rawTxt = String(item.text.prefix(2000))
            let txt = rawTxt.trimmingCharacters(in: .whitespacesAndNewlines)
            if ColorParser.parse(txt) != nil { t = "color" }
            else if txt.hasPrefix("http://") || txt.hasPrefix("https://") || txt.hasPrefix("www.") { t = "link" }
            else {
                let parts = txt.split(separator: "@")
                if parts.count == 2 && parts[1].contains(".") && !txt.contains(" ") { t = "email" }
                else if txt.range(of: "^[0-9 +().-]{5,}$", options: .regularExpression) != nil { t = "number" }
                else if txt.hasPrefix("/") || txt.hasPrefix("file://") { t = "file" }
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
    private var inFlight = Set<String>()
    private var failedIds = Set<String>()

    func image(for item: ClipItem) -> NSImage? {
        let itemId = item.id as NSString
        if let cached = cache.object(forKey: itemId) {
            return cached
        }
        if failedIds.contains(item.id) {
            return nil
        }

        // 1. Direct in-memory image data
        if let data = item.imageData, let img = NSImage(data: data) {
            cache.setObject(img, forKey: itemId)
            return img
        }

        // 2. Local file paths (images, videos, document previews)
        let raw = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let path = getFilePath(from: raw), FileManager.default.fileExists(atPath: path) {
            let ext = (path as NSString).pathExtension.lowercased()
            let fileURL = URL(fileURLWithPath: path)

            // Image file from disk
            if ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "bmp", "icns", "svg"].contains(ext) {
                if let img = NSImage(contentsOfFile: path) {
                    cache.setObject(img, forKey: itemId)
                    return img
                }
            }

            // Async non-blocking thumbnail generation for videos and document previews (zero UI thread lag!)
            if ["mp4", "mov", "m4v", "avi", "webm", "mkv", "pdf", "pptx", "ppt", "docx", "doc", "xlsx", "xls", "key", "pages", "numbers"].contains(ext) {
                if !inFlight.contains(item.id) {
                    inFlight.insert(item.id)
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        let thumb: NSImage?
                        if ["mp4", "mov", "m4v", "avi", "webm", "mkv"].contains(ext) {
                            thumb = self?.generateVideoThumbnail(url: fileURL)
                        } else {
                            thumb = self?.generateDocumentThumbnail(url: fileURL)
                        }

                        DispatchQueue.main.async {
                            self?.inFlight.remove(item.id)
                            if let thumb = thumb {
                                self?.cache.setObject(thumb, forKey: itemId)
                            } else {
                                self?.failedIds.insert(item.id)
                            }
                        }
                    }
                }
            }
        }

        return nil
    }

    private func getFilePath(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        if firstLine.hasPrefix("file://") {
            if let url = URL(string: firstLine) {
                return url.path
            }
            return String(firstLine.dropFirst(7))
        } else if firstLine.hasPrefix("/") {
            return firstLine
        }
        return nil
    }

    private func generateVideoThumbnail(url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.maximumSize = CGSize(width: 320, height: 320)
        let time = CMTime(seconds: 1.0, preferredTimescale: 60)
        if let cgImage = try? imageGenerator.copyCGImage(at: time, actualTime: nil) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        if let cgImage = try? imageGenerator.copyCGImage(at: .zero, actualTime: nil) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return nil
    }

    private func generateDocumentThumbnail(url: URL) -> NSImage? {
        let semaphore = DispatchSemaphore(value: 0)
        var resultImage: NSImage? = nil

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 320, height: 320),
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
            defer { semaphore.signal() }
            guard let rep = representation, error == nil else { return }
            // Only accept actual thumbnail previews, reject generic system icons!
            if rep.type == .thumbnail {
                resultImage = rep.nsImage
            }
        }

        _ = semaphore.wait(timeout: .now() + 0.3)
        return resultImage
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
    private var deepSearchCancellable: AnyCancellable?
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
        // Debounced deep-search: after 300ms of no typing, search inside large payload files
        deepSearchCancellable = $currentSearchText
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] _ in self?.deepSearchPayloads() }
    }

    var historyFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("ClipLocal")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.enc")
    }

    func loadHistory() {
        if let dec = try? Data(contentsOf: historyFile) {
            var arr = (try? JSONDecoder().decode([ClipItem].self, from: CryptoHelper.decrypt(dec, key: key))) ?? []
            // Auto-migrate legacy oversized items out of history.enc into LargePayloadStore
            var migrated = false
            for i in 0..<arr.count {
                if arr[i].payloadFileName == nil && arr[i].text.utf8.count > 15000 && arr[i].text.count > 15000 {
                    let pf = LargePayloadStore.savePayload(id: arr[i].id, text: arr[i].text, key: key)
                    arr[i].payloadFileName = pf
                    arr[i].text = String(arr[i].text.prefix(1500)) + "\n… [Large Clip: 100% full \(arr[i].text.count) characters saved in background storage]"
                    migrated = true
                }
            }
            self.history = arr
            if migrated {
                saveHistory()
            }
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
        for item in history {
            LargePayloadStore.deletePayload(fileName: item.payloadFileName)
        }
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
            let unpinned = history.filter { !$0.pinned }
            let keepUnpinned = Array(unpinned.prefix(Swift.max(0, max - pinned.count)))
            let dropped = unpinned.dropFirst(keepUnpinned.count)
            for item in dropped {
                LargePayloadStore.deletePayload(fileName: item.payloadFileName)
            }
            history = pinned + keepUnpinned
            // Sort back by date
            history.sort { $0.date > $1.date }
            persistIfNeeded()  // keep the on-disk file in sync after a trim
        }
    }

    // MARK: - Instant search (preview text only, runs on every keystroke)
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
            let search = currentSearchText
            result = result.filter { item in
                item.text.range(of: search, options: .caseInsensitive) != nil
            }
        }

        filteredHistory = result.sorted {
            if $0.pinned && !$1.pinned { return true }
            if !$0.pinned && $1.pinned { return false }
            return $0.date > $1.date
        }
    }

    // MARK: - Debounced deep search (payload files, runs 300ms after last keystroke)
    private func deepSearchPayloads() {
        let search = currentSearchText
        guard !search.isEmpty else { return }

        // Only check items that have payloads AND weren't already matched by preview search
        let matchedIds = Set(filteredHistory.map { $0.id })
        let currentKey = key

        // Build the base set (pinned/type filtered) to find payload items not yet matched
        var candidates = history
        if activeFilters.contains("pinned") {
            candidates = candidates.filter { $0.pinned }
        } else {
            candidates = candidates.filter { !$0.pinned }
        }
        let typeFilters = activeFilters.subtracting(["pinned"])
        if !typeFilters.isEmpty {
            candidates = candidates.filter { typeFilters.contains(clipItemType(for: $0)) }
        }

        let payloadCandidates = candidates.filter { $0.payloadFileName != nil && !matchedIds.contains($0.id) }
        guard !payloadCandidates.isEmpty else { return }

        var extraMatches: [ClipItem] = []
        for item in payloadCandidates {
            let full = item.fullText(key: currentKey)
            if full.range(of: search, options: .caseInsensitive) != nil {
                extraMatches.append(item)
            }
        }

        if !extraMatches.isEmpty {
            var merged = filteredHistory + extraMatches
            merged.sort {
                if $0.pinned && !$1.pinned { return true }
                if !$0.pinned && $1.pinned { return false }
                return $0.date > $1.date
            }
            filteredHistory = merged
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
                    FilterButton(title: "Color", systemImage: "paintpalette", filterType: "color", manager: manager)
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
            .scrollContentBackground(.hidden)

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
}

// MARK: - High-Performance Virtualized Large Text Editor
struct LargeTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let contentSize = scrollView.contentSize
        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]

        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor

        // HIGH PERFORMANCE VIRTUALIZATION: Only calculate layout for lines visible on screen!
        textView.layoutManager?.allowsNonContiguousLayout = true

        textView.string = text
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let textView = nsView.documentView as? NSTextView {
            if textView.string != text {
                textView.string = text
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LargeTextEditor
        init(_ parent: LargeTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.parent.text = textView.string
        }
    }
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
    @State private var isLoadingEdit = false

    // MARK: Memoised helpers (computed once per render, not on every sub-view)
    private var itemType: String { clipItemType(for: item) }

    private var iconSystemName: String {
        switch itemType {
        case "code": return "chevron.left.forwardslash.chevron.right"
        case "color": return "paintpalette"
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
        case "color":
            let txt = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if txt.hasPrefix("#") { return "HEX Color" }
            if txt.lowercased().hasPrefix("rgb") { return "RGB Color" }
            if txt.lowercased().hasPrefix("hsl") { return "HSL Color" }
            return "Color"
        case "email": return "Email"
        case "file":
            let raw = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = raw.components(separatedBy: .newlines).first ?? raw
            let clean = firstLine.hasPrefix("file://") ? (URL(string: firstLine)?.path ?? String(firstLine.dropFirst(7))) : firstLine
            let ext = (clean as NSString).pathExtension.lowercased()
            if ["mp4", "mov", "m4v", "avi", "webm", "mkv"].contains(ext) {
                return "\(ext.uppercased()) video"
            } else if ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "bmp", "svg", "icns"].contains(ext) {
                return "\(ext.uppercased()) image"
            }
            return ext.isEmpty ? "File" : "\(ext.uppercased()) file"
        case "image":
            let trimmed = String(item.text.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
            let ext = (trimmed as NSString).pathExtension.uppercased()
            return ext.isEmpty ? "PNG image" : "\(ext) image"
        case "link": return "Link"
        case "number": return "Number"
        default: return "Text"
        }
    }

    private var snippet: String {
        let raw = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if itemType == "file" || raw.hasPrefix("file://") || (raw.hasPrefix("/") && !raw.contains("\n")) {
            let lines = raw.components(separatedBy: .newlines).filter { !$0.isEmpty }
            let fileNames = lines.compactMap { line -> String? in
                let clean: String
                if line.hasPrefix("file://") {
                    clean = URL(string: line)?.path ?? String(line.dropFirst(7))
                } else if line.hasPrefix("/") {
                    clean = line
                } else {
                    return nil
                }
                let name = (clean as NSString).lastPathComponent
                return name.isEmpty ? clean : name
            }
            if !fileNames.isEmpty {
                return fileNames.joined(separator: " ↵ ")
            }
        }

        let maxChars = 500
        let prefixStr = String(item.text.prefix(maxChars + 1))
        let hasMore = prefixStr.utf8.count > maxChars
        let txt = hasMore ? String(prefixStr.prefix(maxChars)) + "…" : prefixStr
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
            } else if let parsedColor = ColorParser.parse(item.text) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: parsedColor))
                }
                .frame(width: 32, height: 32)
                .shadow(color: Color(nsColor: parsedColor).opacity(0.4), radius: 3, x: 0, y: 1.5)
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
        .onTapGesture(count: 2) {
            pasteItem()
        }
        .onTapGesture(count: 1) {
            if manager.expandedIdx.contains(item.id) {
                manager.expandedIdx.remove(item.id)
            } else {
                manager.expandedIdx.insert(item.id)
            }
        }
        .onHover { hovering in
            // Only this row re-renders — ContentView is untouched
            isHovered = hovering
        }
        .listRowBackground(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
        .contextMenu {
            Button(action: {
                let currentKey = manager.key
                let currentItem = item
                isEditing = true
                isLoadingEdit = true
                DispatchQueue.global(qos: .userInitiated).async {
                    let full = currentItem.fullText(key: currentKey)
                    DispatchQueue.main.async {
                        editedText = full
                        isLoadingEdit = false
                    }
                }
            }) {
                Label("Edit", systemImage: "square.and.pencil")
            }
        }
        .sheet(isPresented: $isEditing) {
            VStack(alignment: .leading, spacing: 8) {
                let isReadOnly = editedText.count > 100000
                HStack {
                    Text(isReadOnly ? "View Large Clip" : "Edit Clip")
                        .font(.headline)
                    Spacer()
                    if isReadOnly {
                        HStack(spacing: 4) {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.orange)
                            Text("Read-Only (Over 100k chars)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.12))
                        .cornerRadius(6)
                    }
                }
                if isLoadingEdit {
                    VStack {
                        Spacer()
                        ProgressView("Loading clip content...")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    LargeTextEditor(text: $editedText, isEditable: !isReadOnly)
                        .frame(minWidth: 450, minHeight: 220)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                }
                HStack {
                    Spacer()
                    Button(isReadOnly ? "Done" : "Cancel") { isEditing = false }
                    if !isReadOnly {
                        Button("Save") {
                            if let idx = manager.history.firstIndex(where: { $0.id == item.id }) {
                                if editedText.isEmpty {
                                    let deleted = manager.history.remove(at: idx)
                                    LargePayloadStore.deletePayload(fileName: deleted.payloadFileName)
                                    ItemTypeCache.shared.invalidate(for: item.id)
                                    manager.saveHistory()
                                } else {
                                    var target = manager.history[idx]
                                    LargePayloadStore.deletePayload(fileName: target.payloadFileName)
                                    if editedText.count > 15000 {
                                        let pf = LargePayloadStore.savePayload(id: target.id, text: editedText, key: manager.key)
                                        target.payloadFileName = pf
                                        target.text = String(editedText.prefix(1500)) + "\n… [Large Clip: 100% full \(editedText.count) characters saved in background storage]"
                                    } else {
                                        target.payloadFileName = nil
                                        target.text = editedText
                                    }
                                    target.isEdited = true
                                    manager.history[idx] = target
                                    ItemTypeCache.shared.invalidate(for: item.id)
                                    manager.saveHistory()
                                }
                            }
                            isEditing = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding()
            .frame(width: 520, height: 320)
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
    private func pasteItem() {
        let pb = NSPasteboard.general
        pb.clearContents()

        let fullText = item.fullText(key: manager.key)

        if let data = item.imageData, let img = NSImage(data: data) {
            pb.writeObjects([img])
        } else if fullText.hasPrefix("file://") {
            let path = String(fullText.dropFirst(7))
            pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
        } else {
            pb.setString(fullText, forType: .string)
        }

        manager.lastChangeCount = pb.changeCount
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)

        (NSApp.delegate as? AppDelegate)?.closePopover()
        NSApp.hide(nil)

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

        // Synthesize Command+V to paste directly at active cursor location
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if !AXIsProcessTrusted() {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
                return
            }

            let src = CGEventSource(stateID: .combinedSessionState)
            let vKeyCode: CGKeyCode = 0x09 // 'v' key code

            if let keyDown = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: true),
               let keyUp = CGEvent(keyboardEventSource: src, virtualKey: vKeyCode, keyDown: false) {
                keyDown.flags = .maskCommand
                keyUp.flags = .maskCommand

                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
            }
        }
    }

    private func copyItem() {
        let pb = NSPasteboard.general
        pb.clearContents()

        let fullText = item.fullText(key: manager.key)

        if let data = item.imageData, let img = NSImage(data: data) {
            pb.writeObjects([img])
        } else if fullText.hasPrefix("file://") {
            let path = String(fullText.dropFirst(7))
            pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
        } else {
            pb.setString(fullText, forType: .string)
        }

        manager.lastChangeCount = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        }

        withAnimation { copiedItemId = item.id }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            (NSApp.delegate as? AppDelegate)?.closePopover()
            (NSApp.delegate as? AppDelegate)?.showPreview(fullText)

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
        if let idx = manager.history.firstIndex(where: { $0.id == item.id }) {
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

    private func deleteItem() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        if let idx = manager.history.firstIndex(where: { $0.id == item.id }) {
            let deleted = manager.history.remove(at: idx)
            LargePayloadStore.deletePayload(fileName: deleted.payloadFileName)
            manager.persistIfNeeded()
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
            
            if filterType != "pinned" {
                Button(action: {
                    for i in 0..<manager.history.count {
                        if clipItemType(for: manager.history[i]) == filterType {
                            manager.history[i].pinned = true
                        }
                    }
                    manager.saveHistory()
                }) {
                    Label("Pin All \(label) (\(c.unpinned))", systemImage: "pin")
                }
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

        // Automatically prompt for macOS Accessibility Permission on launch so double-click paste works out of the box
        checkAndPromptAccessibilityPermission()

        if !defaults.bool(forKey: "hideAbout") { showAbout(onLaunch: true) }
        checkForUpdates(silentIfCurrent: true)
    }

    func checkAndPromptAccessibilityPermission() {
        if AXIsProcessTrusted() {
            defaults.set(true, forKey: "hasPromptedAccessibility")
            return
        }

        // Only prompt ONCE on first launch if not yet granted
        if !defaults.bool(forKey: "hasPromptedAccessibility") {
            defaults.set(true, forKey: "hasPromptedAccessibility")
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
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
            popover.animates = true
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            
            // Force popover backdrop NSVisualEffectView state to .active so it stays vivid
            if let window = popover.contentViewController?.view.window {
                func forceActiveState(in view: NSView) {
                    if let vev = view as? NSVisualEffectView {
                        vev.state = .active
                    }
                    for sub in view.subviews {
                        forceActiveState(in: sub)
                    }
                }
                if let root = window.contentView?.superview ?? window.contentView {
                    forceActiveState(in: root)
                }
            }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.showPopover(self.statusItem.button)
        }
    }

    @objc func manualUpdateCheck() { checkForUpdates(silentIfCurrent: false) }
    @objc func quitApp() { NSApp.terminate(nil) }

func getAppLogoImage() -> NSImage {
    if let img = NSImage(named: "AppIcon") {
        return img
    }
    if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"), let img = NSImage(contentsOfFile: path) {
        return img
    }
    if let path = Bundle.main.path(forResource: "AppIcon", ofType: "png"), let img = NSImage(contentsOfFile: path) {
        return img
    }
    if let img = NSImage(contentsOfFile: "AppIcon.png") {
        return img
    }
    if let img = NSImage(contentsOfFile: "../AppIcon.png") {
        return img
    }
    return NSApp.applicationIconImage ?? (NSImage(systemSymbolName: "paperclip.circle", accessibilityDescription: nil) ?? NSImage())
}

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

        let iconSize: CGFloat = 80
        let icon = NSImageView(frame: NSRect(x: (width - iconSize)/2, y: height - 128, width: iconSize, height: iconSize))
        icon.image = getAppLogoImage()
        icon.imageScaling = .scaleProportionallyUpOrDown
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
            ("doc.on.clipboard", "Double-Click Direct Paste", "Double-click any clip item to instantly close the menu and paste it directly where your active cursor is."),
            ("key", "Skips Secrets", "By default, passwords copied from 1Password, Bitwarden, etc., are completely ignored."),
            ("eye.slash", "No Analytics", "Zero telemetry. The app only connects to GitHub manually when you check for updates."),
            ("key.fill", "Keychain Encrypted Storage", "In Persistent mode, your history is encrypted (AES-256 GCM) using hardware-secured keys in Apple's native macOS Keychain."),
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
        var newImageData: Data?
        var newPayloadFileName: String?
        let sourceApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let first = urls.first {
            newText = "file://" + first.path
        } else if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let img = images.first {
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                newImageData = png
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
            
            // Large Payload Storage: If text > 15,000 chars, offload full text to encrypted payload file
            if str.utf8.count > 15000 && str.count > 15000 {
                let itemId = UUID().uuidString
                let pf = LargePayloadStore.savePayload(id: itemId, text: str, key: self.clipboardManager.key)
                newPayloadFileName = pf
                newText = String(str.prefix(1500)) + "\n… [Large Clip: 100% full \(str.count) characters saved in background storage]"
            } else {
                newText = str
            }
        }

        guard let text = newText else { return }

        let isRemote = pb.types?.contains(NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")) ?? false

        // Needs to be run on main thread since it updates @Published history
        DispatchQueue.main.async {
            // Fast duplicate detection: check O(1) byte length before full string equality check
            if let idx = self.clipboardManager.history.firstIndex(where: {
                $0.imageData == newImageData && $0.text.utf8.count == text.utf8.count && $0.text == text
            }) {
                let pinned = self.clipboardManager.history[idx].pinned
                let oldPayload = self.clipboardManager.history[idx].payloadFileName
                self.clipboardManager.history.remove(at: idx)
                let newItem = ClipItem(text: text, date: Date(), pinned: pinned, imageData: newImageData, sourceAppBundleIdentifier: sourceApp, isRemote: isRemote, payloadFileName: newPayloadFileName ?? oldPayload)
                self.clipboardManager.history.insert(newItem, at: 0)
            } else {
                let newItem = ClipItem(text: text, date: Date(), pinned: false, imageData: newImageData, sourceAppBundleIdentifier: sourceApp, isRemote: isRemote, payloadFileName: newPayloadFileName)
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
        let parsedColor = ColorParser.parse(text)
        let bodyX: CGFloat = parsedColor != nil ? 44 : 14
        let bodyWidth: CGFloat = parsedColor != nil ? width - 58 : width - 28

        if let color = parsedColor {
            let swatch = NSView(frame: NSRect(x: 14, y: 12, width: 22, height: 22))
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = color.cgColor
            swatch.layer?.cornerRadius = 5
            swatch.layer?.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
            swatch.layer?.borderWidth = 1
            container.addSubview(swatch)
        }

        title.frame = NSRect(x: bodyX, y: height - 26, width: bodyWidth, height: 18)
        title.font = NSFont.boldSystemFont(ofSize: 12)
        title.textColor = .secondaryLabelColor

        let body = NSTextField(labelWithString: snippet)
        body.frame = NSRect(x: bodyX, y: 8, width: bodyWidth, height: 30)
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
        let now = Date()
        if silentIfCurrent {
            if let lastCheck = defaults.object(forKey: "lastUpdateCheckDate") as? Date,
               now.timeIntervalSince(lastCheck) < 86400 {
                return // Only check once per 24 hours on automatic launch
            }
        }
        defaults.set(now, forKey: "lastUpdateCheckDate")

        URLCache.shared.removeAllCachedResponses()
        let ts = Int(now.timeIntervalSince1970)
        let urlStr = updateCheckURL.contains("?") ? "\(updateCheckURL)&t=\(ts)" : "\(updateCheckURL)?t=\(ts)"
        guard let url = URL(string: urlStr) else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.addValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.addValue("no-cache", forHTTPHeaderField: "Pragma")
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
            if let logs = json["changelog"] as? [[String: Any]] {
                let unreadEntries = logs.filter { entry in
                    if let v = entry["version"] as? String {
                        return self.isNewer(v, than: appVersion)
                    }
                    return false
                }
                notes = unreadEntries.compactMap { entry -> String? in
                    guard let v = entry["version"] as? String,
                          let changes = entry["changes"] as? [String] else { return nil }
                    let changeList = changes.map { "•  \($0)" }.joined(separator: "\n")
                    return "Version \(v):\n\(changeList)"
                }.joined(separator: "\n\n")
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

struct UpdateChangelogView: View {
    let changelog: String

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(changelog)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.primary)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(width: 340, height: 140)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

    func showUpdateResult(_ remote: String?, changelog: String, newer: Bool, downloadURL: String = downloadPageURL) {
        let alert = NSAlert()
        NSApp.activate(ignoringOtherApps: true)
        if newer, let remote = remote {
            alert.messageText = "ClipLocal \(remote) is available"
            alert.informativeText = "You have v\(appVersion). Here's what's new:"
            if !changelog.isEmpty {
                let hosting = NSHostingView(rootView: UpdateChangelogView(changelog: changelog))
                hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 140)
                alert.accessoryView = hosting
            }
            alert.addButton(withTitle: "Update Now")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                downloadAndInstallUpdate()
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
    
    func downloadAndInstallUpdate() {
        let commandURL = "https://raw.githubusercontent.com/arunofhyd/ClipLocal/refs/heads/main/install-cliplocal.command"
        guard let url = URL(string: commandURL) else { return }
        
        let task = URLSession.shared.downloadTask(with: url) { tempURL, _, error in
            DispatchQueue.main.async {
                if let error = error {
                    let err = NSAlert()
                    err.alertStyle = .warning
                    err.messageText = "Download Failed"
                    err.informativeText = "Could not download the update:\n\(error.localizedDescription)\n\nPlease check your internet connection and try again."
                    err.addButton(withTitle: "OK")
                    err.runModal()
                    return
                }
                
                guard let tempURL = tempURL else { return }
                
                let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                let destURL = downloadsDir.appendingPathComponent("install-cliplocal.command")
                
                try? FileManager.default.removeItem(at: destURL)
                do {
                    try FileManager.default.copyItem(at: tempURL, to: destURL)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: NSNumber(value: 0o755)],
                        ofItemAtPath: destURL.path
                    )
                    NSWorkspace.shared.open(destURL)
                } catch {
                    let err = NSAlert()
                    err.alertStyle = .warning
                    err.messageText = "Could Not Save Installer"
                    err.informativeText = "The installer was downloaded but couldn't be saved:\n\(error.localizedDescription)"
                    err.addButton(withTitle: "OK")
                    err.runModal()
                }
            }
        }
        task.resume()
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
