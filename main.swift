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

let appVersion: String = {
    if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !v.isEmpty { return v }
    return "1.3.14"
}()
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

    /// Loads the 256-bit AES-GCM encryption key from macOS Keychain, with automatic
    /// user-isolated 0600 on-disk fallback to prevent repetitive Keychain UI prompts on launch.
    static func loadOrCreateKey() -> Data {
        // 1. Check secure on-disk fallback first (avoids repeated OS Keychain popups across recompiles)
        if let data = try? Data(contentsOf: keyFile), data.count == 32 {
            return data
        }

        // 2. Try loading from macOS Keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            // Mirror to secure fallback file
            try? data.write(to: keyFile, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
            return data
        }

        // 3. Generate a new key and save to both Keychain and secure on-disk store
        let newKey = generateKey()
        
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: newKey,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
        
        try? newKey.write(to: keyFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
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
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 50
        return c
    }()
    private static let finderIcon: NSImage = {
        NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
    }()

    func icon(forBundleID bundleID: String?) -> NSImage {
        guard let bid = bundleID, !bid.isEmpty else { return AppIconCache.finderIcon }
        let key = bid as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let img: NSImage
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            img = NSWorkspace.shared.icon(forFile: appURL.path)
        } else {
            img = AppIconCache.finderIcon
        }

        cache.setObject(img, forKey: key)
        return img
    }
}

// MARK: - Color Parser
struct ColorParser {
    private static let cache = NSCache<NSString, NSColor>()
    private static let rgbaRegex: NSRegularExpression? = {
        let pattern = "^rgba?\\(\\s*(\\d{1,3}%?)\\s*,\\s*(\\d{1,3}%?)\\s*,\\s*(\\d{1,3}%?)(?:\\s*,\\s*([\\d.]+))?\\s*\\)$"
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()
    
    private static let hslaRegex: NSRegularExpression? = {
        let pattern = "^hsla?\\(\\s*(\\d{1,3})\\s*,\\s*(\\d{1,3})%\\s*,\\s*(\\d{1,3})%(?:\\s*,\\s*([\\d.]+))?\\s*\\)$"
        return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }()

    private static let hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    private static let trimChars = CharacterSet(charactersIn: "\"'`;,")

    static func parse(_ text: String) -> NSColor? {
        if text.isEmpty || text.count > 60 { return nil }
        let key = text as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        var str = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.count > 60 || str.isEmpty { return nil }
        
        // Strip common code wrappers/prefixes/suffixes: quotes, semicolons, css properties
        str = str.trimmingCharacters(in: trimChars)
        let lower = str.lowercased()
        if lower.hasPrefix("color:") {
            str = String(str.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if lower.hasPrefix("background-color:") {
            str = String(str.dropFirst(17)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if lower.hasPrefix("background:") {
            str = String(str.dropFirst(11)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        str = str.trimmingCharacters(in: trimChars)
        if str.isEmpty { return nil }
        
        // Fast prefix reject: if it doesn't start with '#', '0x', 'rgb', 'hsl', it's not a color
        let checkLower = str.lowercased()
        guard str.hasPrefix("#") || checkLower.hasPrefix("0x") || checkLower.hasPrefix("rgb") || checkLower.hasPrefix("hsl") else {
            return nil
        }
        
        // Handle 0x prefix if present
        if checkLower.hasPrefix("0x") {
            str = "#" + String(str.dropFirst(2))
        }
        
        // 1. HEX format: #RGB, #RGBA, #RRGGBB, #RRGGBBAA
        let isHexWithHash = str.hasPrefix("#")
        let cleanHex = isHexWithHash ? String(str.dropFirst()) : str
        
        if isHexWithHash && !cleanHex.isEmpty && cleanHex.unicodeScalars.allSatisfy({ hexCharacterSet.contains($0) }) {
            var fullHex = cleanHex
            if cleanHex.count == 3 || cleanHex.count == 4 {
                fullHex = cleanHex.map { "\($0)\($0)" }.joined()
            }
            
            if let val = UInt64(fullHex, radix: 16) {
                let r, g, b, a: CGFloat
                if fullHex.count == 6 {
                    r = CGFloat((val >> 16) & 0xFF) / 255.0
                    g = CGFloat((val >> 8) & 0xFF) / 255.0
                    b = CGFloat(val & 0xFF) / 255.0
                    a = 1.0
                    let color = NSColor(srgbRed: r, green: g, blue: b, alpha: a)
                    cache.setObject(color, forKey: key)
                    return color
                } else if fullHex.count == 8 {
                    r = CGFloat((val >> 24) & 0xFF) / 255.0
                    g = CGFloat((val >> 16) & 0xFF) / 255.0
                    b = CGFloat((val >> 8) & 0xFF) / 255.0
                    a = CGFloat(val & 0xFF) / 255.0
                    let color = NSColor(srgbRed: r, green: g, blue: b, alpha: a)
                    cache.setObject(color, forKey: key)
                    return color
                }
            }
        }
        
        // 2. RGB / RGBA format: rgb(r, g, b) or rgba(r, g, b, a)
        if let regex = rgbaRegex,
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
            let color = NSColor(srgbRed: min(1.0, max(0.0, r)), green: min(1.0, max(0.0, g)), blue: min(1.0, max(0.0, b)), alpha: min(1.0, max(0.0, a)))
            cache.setObject(color, forKey: key)
            return color
        }
        
        // 3. HSL / HSLA format: hsl(h, s%, l%) or hsla(h, s%, l%, a)
        if let regex = hslaRegex,
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
            let color = NSColor(srgbRed: r, green: g, blue: b, alpha: a)
            cache.setObject(color, forKey: key)
            return color
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
    private var cache: NSCache<NSString, NSString> = {
        let c = NSCache<NSString, NSString>()
        c.countLimit = 500
        return c
    }()
    
    func invalidate(for id: String) {
        cache.removeObject(forKey: id as NSString)
    }
    
    private static let interpreterRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "^/(bin|sbin|usr/bin|usr/sbin|usr/local/bin|opt/homebrew/bin)/(bash|sh|zsh|csh|tcsh|dash|python[0-9.]*|node|deno|bun|perl|ruby|env|osascript|pwsh)(\\s+.*|$)",
            options: [.caseInsensitive]
        )
    }()

    private static let cliCommandRegex: NSRegularExpression? = {
        let commands = [
            "sudo", "sh", "bash", "zsh", "fish", "curl", "wget", "brew", "npm", "npx", "pnpm", "yarn", "bun", "pip", "pip3", "pipx",
            "git", "docker", "docker-compose", "podman", "kubectl", "helm", "terraform",
            "chmod", "chown", "chgrp", "mkdir", "pkill", "kill", "killall", "cat", "tail",
            "head", "grep", "egrep", "fgrep", "awk", "sed", "find", "ssh", "scp", "rsync",
            "tar", "zip", "unzip", "touch", "rm", "cp", "mv", "ln", "echo", "printf",
            "export", "alias", "source", "which", "whereis", "uname", "ps", "top", "htop",
            "df", "du", "lsof", "netstat", "ping", "traceroute", "dig", "nslookup",
            "systemctl", "launchctl", "defaults", "xcode-select", "xcrun", "swift", "swiftc",
            "cargo", "rustc", "go", "python", "python3", "node", "deno", "ruby", "perl",
            "php", "java", "javac", "mvn", "gradle", "make", "cmake", "gcc", "g\\+\\+",
            "clang", "clang\\+\\+", "apt", "apt-get", "yum", "dnf", "pacman", "zypper", "apk",
            "open", "man", "history", "clear", "env", "printenv", "set", "unset", "ssh-keygen"
        ].joined(separator: "|")
        return try? NSRegularExpression(
            pattern: "^(sudo\\s+)?(" + commands + ")(\\s+.*|$)",
            options: [.caseInsensitive]
        )
    }()

    private static let numberRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "^[0-9 +().,-]{3,}$")
    }()

    private static let singleLinePathRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "^(/|~/)[^\\s\"'`$|&><;:*?]+$")
    }()

    private static let codeKeywords: [String] = [
        "func ", "function ", "def ", "var ", "let ", "const ", "class ", "struct ",
        "enum ", "interface ", "protocol ", "extension ", "import ", "export ", "package ",
        "namespace ", "public ", "private ", "protected ", "static ", "final ", "override ",
        "async ", "await ", "return ", "yield ", "throw ", "throws ", "try ", "catch ",
        "finally ", "if let ", "guard let ", "console.log", "print(", "println!",
        "System.out.println", "std::", "#include ", "#define ", "#import "
    ]

    private static let codeOperators: [String] = ["=>", "->", "===", "!==", "==", "!=", "+=", "-=", "*=", "/=", "++", "--"]

    private static let markupPrefixes: [String] = ["<!DOCTYPE", "<html", "<head", "<body", "<div", "<span", "<p>", "<a href", "<script", "<style", "<?xml"]

    private static let sqlKeywords: [String] = ["SELECT ", "INSERT INTO ", "UPDATE ", "DELETE FROM ", "CREATE TABLE ", "DROP TABLE ", "ALTER TABLE "]

    static func isCode(_ txt: String) -> Bool {
        let trimmed = txt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }

        // 1. Shebang
        if trimmed.hasPrefix("#!") { return true }

        let range = NSRange(location: 0, length: (trimmed as NSString).length)

        // 2. Direct binary / interpreter invocation with args (e.g. /bin/bash -c "...", /usr/bin/env python3)
        if let regex = interpreterRegex, regex.firstMatch(in: trimmed, options: [], range: range) != nil {
            return true
        }

        // 3. Leading prompt symbols (e.g. "$ brew install ...", ">>> print(x)")
        if trimmed.hasPrefix("$ ") || trimmed.hasPrefix("# ") || trimmed.hasPrefix(">>> ") || trimmed.hasPrefix("➜ ") {
            return true
        }

        // 4. CLI commands at start of string (e.g. "brew install ...", "git push ...", "sudo rm ...", "curl ...")
        if let regex = cliCommandRegex, regex.firstMatch(in: trimmed, options: [], range: range) != nil {
            return true
        }

        // 5. Shell syntax constructs (subshells, pipes, redirects, logical chaining)
        if trimmed.contains("$(") || trimmed.contains("${") || trimmed.contains("`") ||
           trimmed.contains(" | ") || trimmed.contains(" > ") || trimmed.contains(" >> ") ||
           trimmed.contains(" < ") || trimmed.contains(" 2>&1") || trimmed.contains(" &> ") ||
           trimmed.contains(" && ") || trimmed.contains(" || ") {
            return true
        }

        // 6. Dot-slash script execution (e.g. ./install.sh, ./scripts/update.mjs)
        if trimmed.hasPrefix("./") || trimmed.hasPrefix("../") {
            return true
        }

        // 7. Common programming keywords
        if codeKeywords.contains(where: { trimmed.contains($0) }) {
            return true
        }

        // 8. Programming operators & syntax markers
        if codeOperators.contains(where: { trimmed.contains($0) }) {
            return true
        }

        // 9. Markup, config, SQL, JSON structures
        if markupPrefixes.contains(where: { trimmed.lowercased().hasPrefix($0) }) || trimmed.contains("</") || trimmed.contains("/>") {
            return true
        }

        if sqlKeywords.contains(where: { trimmed.uppercased().hasPrefix($0) || trimmed.uppercased().contains(" " + $0) }) {
            return true
        }

        // JSON object or array structure
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}") && trimmed.contains("\":")) ||
           (trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && (trimmed.contains("{\"") || trimmed.contains("\",\""))) {
            return true
        }

        // Semicolon terminated lines or code blocks with { and }
        if (trimmed.contains("{") && trimmed.contains("}")) ||
           (trimmed.contains(";\n") || (trimmed.hasSuffix(";") && trimmed.contains("="))) {
            return true
        }

        // Comments
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || (trimmed.contains("/*") && trimmed.contains("*/")) {
            return true
        }

        return false
    }

    static func isFile(_ txt: String) -> Bool {
        let trimmed = txt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }

        // 1. Finder / system file URLs
        if trimmed.hasPrefix("file://") { return true }

        // If it matches code, it is not a file
        if isCode(trimmed) { return false }

        // 2. Multiline check: if every non-empty line starts with file:// or / or ~/
        if trimmed.contains("\n") {
            let lines = trimmed.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if lines.count > 1 {
                let allLinesArePaths = lines.allSatisfy { line in
                    line.hasPrefix("file://") || line.hasPrefix("/") || line.hasPrefix("~/")
                }
                if allLinesArePaths && !isCode(trimmed) {
                    return true
                }
            }
        }

        // 3. Single-line POSIX path
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                return true
            }

            // Clean path regex (no command arguments or shell operators)
            let range = NSRange(location: 0, length: (trimmed as NSString).length)
            if let regex = singleLinePathRegex, regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                return true
            }
        }

        return false
    }

    func type(for item: ClipItem) -> String {
        let key = item.id as NSString
        if let cached = cache.object(forKey: key) {
            return cached as String
        }
        
        let t: String
        if item.imageData != nil {
            t = "image"
        } else {
            // Clamp type detection to prefix(2000) directly without computing total string count
            let rawTxt = String(item.text.prefix(2000))
            let txt = rawTxt.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if txt.hasPrefix("[Image") && txt.hasSuffix("]") {
                t = "image"
            } else if ColorParser.parse(txt) != nil {
                t = "color"
            } else if (txt.hasPrefix("http://") || txt.hasPrefix("https://") || txt.hasPrefix("www.")) && !txt.contains(" ") && !txt.contains("\n") {
                t = "link"
            } else if ItemTypeCache.isCode(txt) {
                t = "code"
            } else if ItemTypeCache.isFile(txt) {
                t = "file"
            } else {
                let parts = txt.split(separator: "@")
                if parts.count == 2 && parts[1].contains(".") && !txt.contains(" ") && !txt.contains("\n") && !txt.contains("/") {
                    t = "email"
                } else if !txt.contains("\n") && txt.contains(where: { $0.isNumber }) && ItemTypeCache.numberRegex?.firstMatch(in: txt, options: [], range: NSRange(location: 0, length: (txt as NSString).length)) != nil {
                    t = "number"
                } else {
                    t = "text"
                }
            }
        }
        
        cache.setObject(t as NSString, forKey: key)
        return t
    }
}

/// Module-level helper so both ContentView and ClipItemRowView can share
/// the same type-detection logic without duplicating it.
func clipItemType(for item: ClipItem) -> String {
    return ItemTypeCache.shared.type(for: item)
}

// MARK: - Row Presentation Cache
final class RowPresentationCache {
    static let shared = RowPresentationCache()
    
    struct Presentation {
        let type: String
        let iconSystemName: String
        let typeLabel: String
        let snippet: String
        let formattedDate: String
        let color: NSColor?
    }
    
    private let cache = NSCache<NSString, PresentationBox>()
    
    private final class PresentationBox {
        let presentation: Presentation
        init(_ presentation: Presentation) {
            self.presentation = presentation
        }
    }
    
    func presentation(for item: ClipItem) -> Presentation {
        let key = item.id as NSString
        if let box = cache.object(forKey: key) {
            return box.presentation
        }
        
        let p = buildPresentation(for: item)
        cache.setObject(PresentationBox(p), forKey: key)
        return p
    }
    
    func invalidate(for id: String) {
        cache.removeObject(forKey: id as NSString)
    }
    
    private func buildPresentation(for item: ClipItem) -> Presentation {
        let type = clipItemType(for: item)
        let iconName: String
        switch type {
        case "code": iconName = "chevron.left.forwardslash.chevron.right"
        case "color": iconName = "paintpalette"
        case "email": iconName = "envelope"
        case "file": iconName = "doc"
        case "image": iconName = "photo"
        case "link": iconName = "link"
        case "number": iconName = "number"
        default: iconName = "text.alignleft"
        }
        
        let label: String
        switch type {
        case "code": label = "Code"
        case "color":
            let txt = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if txt.hasPrefix("#") { label = "HEX Color" }
            else if txt.lowercased().hasPrefix("rgb") { label = "RGB Color" }
            else if txt.lowercased().hasPrefix("hsl") { label = "HSL Color" }
            else { label = "Color" }
        case "file":
            let raw = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = raw.components(separatedBy: .newlines).first ?? raw
            let clean = firstLine.hasPrefix("file://") ? (URL(string: firstLine)?.path ?? String(firstLine.dropFirst(7))) : firstLine
            let ext = (clean as NSString).pathExtension.lowercased()
            if ["mp4", "mov", "m4v", "avi", "webm", "mkv"].contains(ext) {
                label = "\(ext.uppercased()) video"
            } else if ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "bmp", "svg", "icns"].contains(ext) {
                label = "\(ext.uppercased()) image"
            } else {
                label = ext.isEmpty ? "File" : "\(ext.uppercased()) file"
            }
        case "image":
            let trimmed = String(item.text.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
            let ext = (trimmed as NSString).pathExtension.uppercased()
            label = ext.isEmpty ? "PNG image" : "\(ext) image"
        case "link": label = "Link"
        case "number": label = "Number"
        default: label = "Text"
        }
        
        let snip: String
        if item.id == "__cliplocal_tutorial_item__" {
            snip = "Sample Clipboard Item"
        } else if type == "file" || item.text.hasPrefix("file://") {
            let raw = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = raw.components(separatedBy: .newlines).filter { !$0.isEmpty }
            let fileNames = lines.compactMap { line -> String? in
                let clean: String
                if line.hasPrefix("file://") {
                    clean = URL(string: line)?.path ?? String(line.dropFirst(7))
                } else if line.hasPrefix("/") || line.hasPrefix("~/") {
                    clean = (line as NSString).expandingTildeInPath
                } else {
                    return nil
                }
                let name = (clean as NSString).lastPathComponent
                return name.isEmpty ? clean : name
            }
            snip = fileNames.isEmpty ? raw : fileNames.joined(separator: " ↵ ")
        } else {
            let maxChars = 500
            let prefixStr = String(item.text.prefix(maxChars + 1))
            let hasMore = prefixStr.utf8.count > maxChars
            let txt = hasMore ? String(prefixStr.prefix(maxChars)) + "…" : prefixStr
            snip = txt.replacingOccurrences(of: "\n", with: " ↵ ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        let dateStr = sharedDateFormatter.string(from: item.date)
        let color: NSColor? = (type == "color") ? ColorParser.parse(item.text) : nil
        
        return Presentation(
            type: type,
            iconSystemName: iconName,
            typeLabel: label,
            snippet: snip,
            formattedDate: dateStr,
            color: color
        )
    }
}

enum PrivacyMode: String {
    case session
    case persistent
}

// MARK: - Image Preview & Hardware-Accelerated Downsampled Thumbnail Cache
class ImagePreviewCache {
    static let shared = ImagePreviewCache()
    private let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300 // Cap memory footprint (64KB per thumb * 300 = ~19MB max)
        return cache
    }()
    
    private let fullImageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 10 // Prevent massive memory balloons from multiple expanded full-res images
        return cache
    }()
    
    private var inFlight = Set<String>()
    private var failedIds = Set<String>()
    private let lock = NSLock()

    func thumbnail(for item: ClipItem) -> NSImage? {
        let itemId = item.id as NSString
        if let cached = thumbnailCache.object(forKey: itemId) {
            return cached
        }
        
        lock.lock()
        if failedIds.contains(item.id) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        // 1. Direct in-memory image data: hardware downsample directly into 64x64 @2x thumbnail
        if let data = item.imageData {
            if let thumb = ImagePreviewCache.createDownsampledThumbnail(from: data, maxPixelSize: 64) {
                thumbnailCache.setObject(thumb, forKey: itemId)
                return thumb
            }
        }

        // 2. Local file paths (images, videos, document previews)
        let raw = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let path = getFilePath(from: raw), FileManager.default.fileExists(atPath: path) {
            let ext = (path as NSString).pathExtension.lowercased()
            let fileURL = URL(fileURLWithPath: path)

            // Image file from disk: fast hardware-downsampled thumbnail
            if ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "bmp", "icns", "svg"].contains(ext) {
                if let thumb = ImagePreviewCache.createDownsampledThumbnail(from: fileURL, maxPixelSize: 64) {
                    thumbnailCache.setObject(thumb, forKey: itemId)
                    return thumb
                } else if let img = NSImage(contentsOfFile: path) {
                    thumbnailCache.setObject(img, forKey: itemId)
                    return img
                }
            }

            // Async non-blocking thumbnail generation for videos and document previews
            if ["mp4", "mov", "m4v", "avi", "webm", "mkv", "pdf", "pptx", "ppt", "docx", "doc", "xlsx", "xls", "key", "pages", "numbers"].contains(ext) {
                lock.lock()
                let alreadyInFlight = inFlight.contains(item.id)
                if !alreadyInFlight {
                    inFlight.insert(item.id)
                }
                lock.unlock()

                if !alreadyInFlight {
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        let thumb: NSImage?
                        if ["mp4", "mov", "m4v", "avi", "webm", "mkv"].contains(ext) {
                            thumb = self?.generateVideoThumbnail(url: fileURL)
                        } else {
                            thumb = self?.generateDocumentThumbnail(url: fileURL)
                        }

                        DispatchQueue.main.async {
                            guard let self = self else { return }
                            self.lock.lock()
                            self.inFlight.remove(item.id)
                            if let thumb = thumb {
                                self.thumbnailCache.setObject(thumb, forKey: itemId)
                            } else {
                                self.failedIds.insert(item.id)
                            }
                            self.lock.unlock()
                        }
                    }
                }
                return nil
            }
        }

        lock.lock()
        failedIds.insert(item.id)
        lock.unlock()
        return nil
    }

    func fullImage(for item: ClipItem) -> NSImage? {
        let itemId = item.id as NSString
        if let cached = fullImageCache.object(forKey: itemId) {
            return cached
        }

        lock.lock()
        if failedIds.contains(item.id) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        if let data = item.imageData, let img = NSImage(data: data) {
            fullImageCache.setObject(img, forKey: itemId)
            return img
        }

        let raw = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let path = getFilePath(from: raw), FileManager.default.fileExists(atPath: path) {
            let ext = (path as NSString).pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "bmp", "icns", "svg"].contains(ext) {
                if let img = NSImage(contentsOfFile: path) {
                    fullImageCache.setObject(img, forKey: itemId)
                    return img
                }
            }
        }

        lock.lock()
        failedIds.insert(item.id)
        lock.unlock()
        return nil
    }

    func invalidate(for id: String) {
        let key = id as NSString
        thumbnailCache.removeObject(forKey: key)
        fullImageCache.removeObject(forKey: key)
        lock.lock()
        failedIds.remove(id)
        inFlight.remove(id)
        lock.unlock()
    }

    static func createDownsampledThumbnail(from data: Data, maxPixelSize: CGFloat = 64) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }
        return NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width / 2, height: cgThumb.height / 2))
    }

    static func createDownsampledThumbnail(from fileURL: URL, maxPixelSize: CGFloat = 64) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, options as CFDictionary) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }
        return NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width / 2, height: cgThumb.height / 2))
    }

    private func getFilePath(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        if firstLine.hasPrefix("file://") {
            if let url = URL(string: firstLine) {
                return url.path
            }
            return String(firstLine.dropFirst(7))
        } else if firstLine.hasPrefix("/") || firstLine.hasPrefix("~/") {
            return (firstLine as NSString).expandingTildeInPath
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

enum TutorialStep: Int, CaseIterable {
    case step1_pin = 1
    case step2_goToPinned = 2
    case step3_rightClickPill = 3
    case step4_editClip = 4
    case step5_doubleClickPaste = 5
    case step6_delete = 6
    case completed = 7
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
    @Published var pinFlash: Bool
    @Published var isTutorialActive: Bool
    @Published var tutorialStep: TutorialStep
    @Published var tutorialItem: ClipItem
    @Published var isSimulatingPaste: Bool = false
    @Published var showPillHighlight: Bool = false

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
        get { defaults.object(forKey: "maxItems") as? Int ?? 1000 }
        set { defaults.set(newValue, forKey: "maxItems"); trimHistory() }
    }

    init() {
        self.resizableMenu = UserDefaults.standard.object(forKey: "resizableMenu") as? Bool ?? false
        self.menuHeight = UserDefaults.standard.object(forKey: "menuHeight") as? Double ?? 500.0
        self.pinFlash = false

        let tutorialCompleted = UserDefaults.standard.bool(forKey: "hasCompletedInteractiveTutorial_v1")
        self.isTutorialActive = !tutorialCompleted
        self.tutorialStep = .step1_pin
        self.tutorialItem = ClipItem(
            id: "__cliplocal_tutorial_item__",
            text: "Tutorial Placeholder: Swipe right to Pin 📌, Double-click to Paste 📋, Swipe left to Delete 🗑️",
            date: Date(),
            isEdited: false,
            pinned: false,
            imageData: nil,
            sourceAppBundleIdentifier: "com.apple.finder"
        )

        if mode == .persistent { loadHistory() }
        
        if isTutorialActive && !history.contains(where: { $0.id == "__cliplocal_tutorial_item__" }) {
            history.insert(tutorialItem, at: 0)
        }

        // Debounced deep-search: after 300ms of no typing, search inside large payload files
        deepSearchCancellable = $currentSearchText
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] _ in self?.deepSearchPayloads() }
    }

    func finishTutorialNow() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            isTutorialActive = false
            tutorialStep = .completed
            showPillHighlight = false
            history.removeAll { $0.id == "__cliplocal_tutorial_item__" }
            activeFilters.remove("pinned")
        }
        UserDefaults.standard.set(true, forKey: "hasCompletedInteractiveTutorial_v1")
    }

    func nextTutorialStep() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            switch tutorialStep {
            case .step1_pin:
                tutorialStep = .step2_goToPinned
            case .step2_goToPinned:
                tutorialStep = .step3_rightClickPill
                startStep3PillHighlightDelay()
            case .step3_rightClickPill:
                tutorialStep = .step4_editClip
            case .step4_editClip:
                tutorialStep = .step5_doubleClickPaste
            case .step5_doubleClickPaste:
                tutorialStep = .step6_delete
            case .step6_delete, .completed:
                finishTutorialNow()
            }
        }
    }

    func skipTutorial() {
        finishTutorialNow()
    }

    func resetTutorial() {
        history.removeAll { $0.id == "__cliplocal_tutorial_item__" }
        tutorialItem = ClipItem(
            id: "__cliplocal_tutorial_item__",
            text: "Tutorial Placeholder: Swipe right to Pin 📌, Double-click to Paste 📋, Swipe left to Delete 🗑️",
            date: Date(),
            isEdited: false,
            pinned: false,
            imageData: nil,
            sourceAppBundleIdentifier: "com.apple.finder"
        )
        tutorialStep = .step1_pin
        isTutorialActive = true
        isSimulatingPaste = false
        showPillHighlight = false
        UserDefaults.standard.set(false, forKey: "hasCompletedInteractiveTutorial_v1")
        activeFilters.remove("pinned")
        history.insert(tutorialItem, at: 0)
    }

    func startStep3PillHighlightDelay() {
        showPillHighlight = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.isTutorialActive, self.tutorialStep == .step3_rightClickPill else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) {
                self.showPillHighlight = true
            }
        }
    }

    // MARK: - Tutorial Action Handlers
    func pinTutorialItem() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        if let idx = history.firstIndex(where: { $0.id == "__cliplocal_tutorial_item__" }) {
            history[idx].pinned = true
            history.sort {
                if $0.pinned == $1.pinned { return $0.date > $1.date }
                return $0.pinned && !$1.pinned
            }
        }
        tutorialItem.pinned = true
        pinFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.pinFlash = false
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            tutorialStep = .step2_goToPinned
        }
    }

    func onFilterTabSelected(filter: String) {
        if isTutorialActive && tutorialStep == .step2_goToPinned && filter == "pinned" {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                tutorialStep = .step3_rightClickPill
            }
            startStep3PillHighlightDelay()
        }
    }

    func deleteTutorialItem() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        history.removeAll { $0.id == "__cliplocal_tutorial_item__" }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            tutorialStep = .completed
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.finishTutorialNow()
        }
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
        if isTutorialActive && !self.history.contains(where: { $0.id == "__cliplocal_tutorial_item__" }) {
            self.history.insert(tutorialItem, at: 0)
        }
        updateFilteredHistory()
    }

    func saveHistory() {
        // Capture values on the main thread, then encrypt + write in the background.
        let snapshot = history.filter { $0.id != "__cliplocal_tutorial_item__" }
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
                    let isAllTutorialTarget = manager.isTutorialActive && manager.tutorialStep == .step3_rightClickPill && manager.showPillHighlight
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
                        .background(manager.activeFilters.isEmpty ? Color.blue : (isAllTutorialTarget ? Color.teal.opacity(0.35) : Color.secondary.opacity(0.1)))
                        .foregroundColor(manager.activeFilters.isEmpty ? .white : (isAllTutorialTarget ? .teal : .primary))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(isAllTutorialTarget ? Color.teal : Color.secondary.opacity(0.2), lineWidth: isAllTutorialTarget ? 1.5 : (manager.activeFilters.isEmpty ? 0 : 1))
                        )
                        .scaleEffect(isAllTutorialTarget ? 1.1 : 1.0)
                        .shadow(color: isAllTutorialTarget ? Color.teal.opacity(0.5) : Color.clear, radius: isAllTutorialTarget ? 4 : 0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isAllTutorialTarget)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Right-click for mass actions")
                    .contextMenu {
                        let c = manager.filterCounts["all"] ?? TypeCount()
                        
                        Group {
                            Button(action: {
                                if isAllTutorialTarget {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                        manager.tutorialStep = .step4_editClip
                                    }
                                }
                                for i in 0..<manager.history.count {
                                    manager.history[i].pinned = true
                                }
                                manager.saveHistory()
                            }) {
                                Label("Pin All Items (\(c.unpinned))", systemImage: "pin")
                            }
                            
                            Button(action: {
                                if isAllTutorialTarget {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                        manager.tutorialStep = .step4_editClip
                                    }
                                }
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
                        .onAppear {
                            if manager.isTutorialActive && manager.tutorialStep == .step3_rightClickPill {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                    manager.tutorialStep = .step4_editClip
                                }
                            }
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

            // Interactive First-Time Tutorial Guidance Banner
            if manager.isTutorialActive {
                TutorialGuidanceBanner(manager: manager)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Divider()
            }

            // List
            ScrollViewReader { proxy in
                List {
                    if manager.filteredHistory.isEmpty {
                        Text("— empty —")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else if manager.activeFilters.isEmpty && manager.currentSearchText.isEmpty {
                        let topCount = min(9, manager.filteredHistory.count)
                        ForEach(0..<topCount, id: \.self) { idx in
                            let item = manager.filteredHistory[idx]
                            ClipItemRowView(
                                item: item,
                                shortcutIndex: idx,
                                isCopied: copiedItemId == item.id,
                                isExpanded: manager.expandedIdx.contains(item.id),
                                isTutorialActive: manager.isTutorialActive,
                                tutorialStep: manager.isTutorialActive ? manager.tutorialStep : nil,
                                isSimulatingPaste: manager.isSimulatingPaste,
                                onCopy: { copyItem(item) },
                                onPaste: { pasteItem(item) },
                                onTogglePin: { togglePin(item) },
                                onDelete: { deleteItem(item) },
                                onEdit: { newText in editItem(item, newText: newText) },
                                onToggleExpand: { toggleExpand(item) },
                                loadFullText: { item.fullText(key: manager.key) }
                            )
                            .equatable()
                            .id(item.id)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        }
                        ForEach(manager.filteredHistory.dropFirst(topCount), id: \.id) { item in
                            ClipItemRowView(
                                item: item,
                                shortcutIndex: nil,
                                isCopied: copiedItemId == item.id,
                                isExpanded: manager.expandedIdx.contains(item.id),
                                isTutorialActive: manager.isTutorialActive,
                                tutorialStep: manager.isTutorialActive ? manager.tutorialStep : nil,
                                isSimulatingPaste: manager.isSimulatingPaste,
                                onCopy: { copyItem(item) },
                                onPaste: { pasteItem(item) },
                                onTogglePin: { togglePin(item) },
                                onDelete: { deleteItem(item) },
                                onEdit: { newText in editItem(item, newText: newText) },
                                onToggleExpand: { toggleExpand(item) },
                                loadFullText: { item.fullText(key: manager.key) }
                            )
                            .equatable()
                            .id(item.id)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        }
                    } else {
                        ForEach(manager.filteredHistory, id: \.id) { item in
                            ClipItemRowView(
                                item: item,
                                shortcutIndex: nil,
                                isCopied: copiedItemId == item.id,
                                isExpanded: manager.expandedIdx.contains(item.id),
                                isTutorialActive: manager.isTutorialActive,
                                tutorialStep: manager.isTutorialActive ? manager.tutorialStep : nil,
                                isSimulatingPaste: manager.isSimulatingPaste,
                                onCopy: { copyItem(item) },
                                onPaste: { pasteItem(item) },
                                onTogglePin: { togglePin(item) },
                                onDelete: { deleteItem(item) },
                                onEdit: { newText in editItem(item, newText: newText) },
                                onToggleExpand: { toggleExpand(item) },
                                loadFullText: { item.fullText(key: manager.key) }
                            )
                            .equatable()
                            .id(item.id)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onAppear {
                    if let firstId = manager.filteredHistory.first?.id {
                        proxy.scrollTo(firstId, anchor: .top)
                    }
                }
                .onChange(of: manager.filteredHistory.first?.id) { _, firstId in
                    if let firstId = firstId {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(firstId, anchor: .top)
                        }
                    }
                }
            }

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

    // MARK: - Row Actions
    private func toggleExpand(_ item: ClipItem) {
        if manager.expandedIdx.contains(item.id) {
            manager.expandedIdx.remove(item.id)
        } else {
            manager.expandedIdx.insert(item.id)
        }
    }

    private func togglePin(_ item: ClipItem) {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        if let idx = manager.history.firstIndex(where: { $0.id == item.id }) {
            manager.history[idx].pinned.toggle()
            let wasPinned = manager.history[idx].pinned
            manager.history.sort {
                if $0.pinned == $1.pinned { return $0.date > $1.date }
                return $0.pinned && !$1.pinned
            }
            RowPresentationCache.shared.invalidate(for: item.id)
            manager.persistIfNeeded()
            if wasPinned {
                manager.pinFlash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    manager.pinFlash = false
                }
            }

            if item.id == "__cliplocal_tutorial_item__" && manager.isTutorialActive {
                if wasPinned && manager.tutorialStep == .step1_pin {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        manager.tutorialStep = .step2_goToPinned
                    }
                }
            }
        }
    }

    private func deleteItem(_ item: ClipItem) {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        if let idx = manager.history.firstIndex(where: { $0.id == item.id }) {
            let deleted = manager.history.remove(at: idx)
            LargePayloadStore.deletePayload(fileName: deleted.payloadFileName)
            ItemTypeCache.shared.invalidate(for: item.id)
            RowPresentationCache.shared.invalidate(for: item.id)
            ImagePreviewCache.shared.invalidate(for: item.id)
            manager.persistIfNeeded()

            if item.id == "__cliplocal_tutorial_item__" && manager.isTutorialActive {
                if manager.tutorialStep == .step6_delete {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        manager.tutorialStep = .completed
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        manager.finishTutorialNow()
                    }
                }
            }
        }
    }

    private func pasteItem(_ item: ClipItem) {
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

        if item.id == "__cliplocal_tutorial_item__" && manager.isTutorialActive {
            if manager.tutorialStep == .step5_doubleClickPaste {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    manager.isSimulatingPaste = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        manager.isSimulatingPaste = false
                        manager.tutorialStep = .step6_delete
                    }
                }
            }
            return
        }

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
            RowPresentationCache.shared.invalidate(for: item.id)
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

    private func copyItem(_ item: ClipItem) {
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
                    RowPresentationCache.shared.invalidate(for: item.id)
                    manager.persistIfNeeded()
                }
                if copiedItemId == item.id { copiedItemId = nil }
            }
        }
    }

    private func editItem(_ item: ClipItem, newText: String) {
        guard let idx = manager.history.firstIndex(where: { $0.id == item.id }) else { return }
        if newText.isEmpty {
            let deleted = manager.history.remove(at: idx)
            LargePayloadStore.deletePayload(fileName: deleted.payloadFileName)
            ItemTypeCache.shared.invalidate(for: item.id)
            RowPresentationCache.shared.invalidate(for: item.id)
            ImagePreviewCache.shared.invalidate(for: item.id)
            manager.saveHistory()
        } else {
            var target = manager.history[idx]
            LargePayloadStore.deletePayload(fileName: target.payloadFileName)
            if newText.count > 15000 {
                let pf = LargePayloadStore.savePayload(id: target.id, text: newText, key: manager.key)
                target.payloadFileName = pf
                target.text = String(newText.prefix(1500)) + "\n… [Large Clip: 100% full \(newText.count) characters saved in background storage]"
            } else {
                target.payloadFileName = nil
                target.text = newText
            }
            target.isEdited = true
            manager.history[idx] = target
            ItemTypeCache.shared.invalidate(for: item.id)
            RowPresentationCache.shared.invalidate(for: item.id)
            ImagePreviewCache.shared.invalidate(for: item.id)
            manager.saveHistory()
        }
    }
}

// MARK: - Interactive First-Time Tutorial Guidance Banner
struct TutorialGuidanceBanner: View {
    @ObservedObject var manager: ClipboardManager

    private var bannerTitle: String {
        if manager.isSimulatingPaste {
            return "Pasting at active cursor... ✨"
        }
        switch manager.tutorialStep {
        case .step1_pin:
            return "Swipe right to Pin 📌"
        case .step2_goToPinned:
            return "Click 📌 Pinned tab above"
        case .step3_rightClickPill:
            return "Right-click pills for batch actions"
        case .step4_editClip:
            return "Right-click row to Edit ✏️"
        case .step5_doubleClickPaste:
            return "Double-click row to Paste 📋"
        case .step6_delete:
            return "Swipe left to Delete 🗑️"
        case .completed:
            return "All set! ClipLocal is ready 🎉"
        }
    }

    private var bannerColor: Color {
        if manager.isSimulatingPaste { return .purple }
        switch manager.tutorialStep {
        case .step1_pin: return .orange
        case .step2_goToPinned: return .blue
        case .step3_rightClickPill: return .teal
        case .step4_editClip: return .indigo
        case .step5_doubleClickPaste: return .purple
        case .step6_delete: return .red
        case .completed: return .green
        }
    }

    private var bannerIcon: String {
        if manager.isSimulatingPaste { return "sparkles" }
        switch manager.tutorialStep {
        case .step1_pin: return "pin.fill"
        case .step2_goToPinned: return "arrow.up.circle.fill"
        case .step3_rightClickPill: return "ellipsis.circle.fill"
        case .step4_editClip: return "square.and.pencil"
        case .step5_doubleClickPaste: return "cursorarrow.rays"
        case .step6_delete: return "trash.fill"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private var stepIndex: Int {
        manager.tutorialStep.rawValue
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: bannerIcon)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(bannerColor)

            if manager.tutorialStep != .completed {
                HStack(spacing: 3) {
                    ForEach(1...6, id: \.self) { idx in
                        Capsule()
                            .fill(idx <= stepIndex ? bannerColor : Color.secondary.opacity(0.25))
                            .frame(width: idx == stepIndex ? 10 : 4, height: 4)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: stepIndex)
                    }
                }
            }

            Text(bannerTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer()

            if manager.tutorialStep != .completed {
                HStack(spacing: 8) {
                    Button(action: {
                        manager.nextTutorialStep()
                    }) {
                        Text("Next ➔")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(bannerColor)
                    }
                    .buttonStyle(PlainButtonStyle())

                    Button(action: {
                        manager.skipTutorial()
                    }) {
                        Text("Skip")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(bannerColor.opacity(0.12))
        .cornerRadius(6)
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

// MARK: - Interactive Active App Paste Simulator
struct InteractivePasteSimulatorView: View {
    let isSimulatingPaste: Bool
    @State private var phase: Int = 0
    @State private var isPasted: Bool = false
    @State private var showPasteGlow: Bool = false
    @State private var cursorVisible: Bool = true
    
    let sampleText = "Tutorial Placeholder Item"
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // macOS Window Titlebar
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle().fill(Color(nsColor: .systemRed)).frame(width: 8, height: 8)
                    Circle().fill(Color(nsColor: .systemYellow)).frame(width: 8, height: 8)
                    Circle().fill(Color(nsColor: .systemGreen)).frame(width: 8, height: 8)
                }
                
                Spacer()
                
                HStack(spacing: 4) {
                    Image(systemName: "note.text")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.orange)
                    Text("Notes — Active Window Simulator")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if phase >= 2 {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 10))
                        Text("Pasted!")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.green)
                    }
                    .transition(.scale.combined(with: .opacity))
                } else if phase == 1 {
                    HStack(spacing: 3) {
                        Text("⌘V")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(3)
                        Text("Pasting...")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(.blue)
                    }
                    .transition(.scale.combined(with: .opacity))
                } else {
                    HStack(spacing: 3) {
                        Text("⌘V")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(3)
                        Text("Auto-Paste")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.12))
            
            Divider()
            
            // Document Content Area
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("1")
                        .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.5))
                        .frame(width: 12, alignment: .trailing)
                    Text("Meeting Notes — Project Summary:")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                }
                
                HStack(alignment: .center, spacing: 6) {
                    Text("2")
                        .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.5))
                        .frame(width: 12, alignment: .trailing)
                    
                    if isPasted {
                        HStack(spacing: 0) {
                            Text(sampleText)
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(.primary)
                            
                            Rectangle()
                                .fill(Color.accentColor)
                                .frame(width: 2, height: 13)
                                .opacity(cursorVisible ? 1.0 : 0.0)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(showPasteGlow ? Color.accentColor.opacity(0.28) : Color.clear)
                        .cornerRadius(3)
                        .scaleEffect(showPasteGlow ? 1.03 : 1.0)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    } else {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 2, height: 13)
                            .opacity(cursorVisible ? 1.0 : 0.0)
                            .padding(.leading, 4)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(phase >= 2 ? Color.green.opacity(0.6) : (showPasteGlow ? Color.blue.opacity(0.7) : Color.accentColor.opacity(0.4)), lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.1), radius: 4, y: 2)
        .onAppear {
            runPasteAnimation()
        }
    }
    
    private func runPasteAnimation() {
        cursorVisible = true
        phase = 0
        isPasted = false
        showPasteGlow = false
        
        Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { timer in
            if !isSimulatingPaste {
                timer.invalidate()
                return
            }
            cursorVisible.toggle()
        }
        
        // Instant Paste Impact (after 200ms)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                phase = 1
                isPasted = true
                showPasteGlow = true
            }
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
            
            // Fade selection highlight (after 450ms)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showPasteGlow = false
                    phase = 2
                }
            }
        }
    }
}

// MARK: - ClipItemRowView
/// A high-performance, Equatable row view for each clipboard item.
/// Fully decoupled from global manager observations so scrolling over 300+ items
/// evaluates in zero nanoseconds without triggering list-wide SwiftUI diff cascades.
struct ClipItemRowView: View, Equatable {
    let item: ClipItem
    let shortcutIndex: Int?
    let isCopied: Bool
    let isExpanded: Bool
    let isTutorialActive: Bool
    let tutorialStep: TutorialStep?
    let isSimulatingPaste: Bool

    let onCopy: () -> Void
    let onPaste: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    let onEdit: (String) -> Void
    let onToggleExpand: () -> Void
    let loadFullText: () -> String

    /// Local hover state — changes here never propagate up to ContentView.
    @State private var isHovered = false
    @State private var lastClickTime = Date.distantPast
    @State private var pendingExpandWorkItem: DispatchWorkItem? = nil
    
    // Edit state
    @State private var isEditing = false
    @State private var editedText = ""
    @State private var isLoadingEdit = false

    // Tutorial demo state
    @State private var demoSwipeOffset: CGFloat = 0
    @State private var demoTimer: Timer? = nil

    private var isTutorialItem: Bool {
        item.id == "__cliplocal_tutorial_item__" && isTutorialActive
    }

    static func == (lhs: ClipItemRowView, rhs: ClipItemRowView) -> Bool {
        return lhs.item == rhs.item &&
               lhs.shortcutIndex == rhs.shortcutIndex &&
               lhs.isCopied == rhs.isCopied &&
               lhs.isExpanded == rhs.isExpanded &&
               lhs.isTutorialActive == rhs.isTutorialActive &&
               lhs.tutorialStep == rhs.tutorialStep &&
               lhs.isSimulatingPaste == rhs.isSimulatingPaste
    }

    var body: some View {
        let presentation = RowPresentationCache.shared.presentation(for: item)
        let thumbnail = ImagePreviewCache.shared.thumbnail(for: item)
        let appIcon = AppIconCache.shared.icon(forBundleID: item.sourceAppBundleIdentifier)

        ZStack(alignment: .leading) {
            if isTutorialItem {
                if demoSwipeOffset > 5 {
                    // Leading Action Indicator (Pin)
                    HStack(spacing: 5) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("Pin")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(width: demoSwipeOffset)
                    .frame(maxHeight: .infinity)
                    .background(Color.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else if demoSwipeOffset < -5 {
                    // Trailing Action Indicator (Delete)
                    HStack {
                        Spacer()
                        HStack(spacing: 5) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 13, weight: .bold))
                            Text("Delete")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(width: abs(demoSwipeOffset))
                        .frame(maxHeight: .infinity)
                        .background(Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            if isTutorialItem && isSimulatingPaste {
                InteractivePasteSimulatorView(isSimulatingPaste: isSimulatingPaste)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.96).combined(with: .opacity),
                        removal: .opacity
                    ))
            } else {
                // Foreground Row (Opaque background so peek action remains neatly behind without text bleed)
                HStack(alignment: .center, spacing: 16) {
                    if let thumb = thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else if let parsedColor = presentation.color {
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
                        Image(systemName: presentation.iconSystemName)
                            .font(.system(size: 16, weight: .light))
                            .foregroundColor(isTutorialItem ? (tutorialStep == .step5_doubleClickPaste ? .purple : (tutorialStep == .step4_editClip ? .indigo : .orange)) : .secondary)
                            .frame(width: 32)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        if presentation.snippet != "[Image]" {
                            Text(presentation.snippet)
                                .lineLimit(isExpanded ? 5 : 1)
                                .truncationMode(.tail)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.primary)
                        }

                        if isExpanded, let fullImg = ImagePreviewCache.shared.fullImage(for: item) {
                            Image(nsImage: fullImg)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 200, alignment: .leading)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .padding(.vertical, 4)
                        }

                        HStack(spacing: 4) {
                            // Icon is served from cache — no disk I/O on hot path
                            Image(nsImage: appIcon)
                                .resizable()
                                .frame(width: 12, height: 12)
                                .clipShape(Circle())

                            if isTutorialItem {
                                if tutorialStep == .step1_pin {
                                    Text("Swipe right across row to Pin 📌")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundColor(.orange)
                                } else if tutorialStep == .step2_goToPinned {
                                    Text("Click the 📌 Pinned tab in top bar")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundColor(.blue)
                                } else if tutorialStep == .step3_rightClickPill {
                                    Text("Right-click any filter pill above for batch options")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundColor(.teal)
                                } else if tutorialStep == .step4_editClip {
                                    Text("Right-click this row & choose Edit ✏️")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundColor(.indigo)
                                } else if tutorialStep == .step5_doubleClickPaste {
                                    Text("Double-click anywhere on row to Paste 📋")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundColor(.purple)
                                } else if tutorialStep == .step6_delete {
                                    Text("Swipe left across row to Delete 🗑️")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundColor(.red)
                                } else {
                                    Text("Tutorial Complete")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundColor(.green)
                                }
                            } else {
                                if let thumb = thumbnail {
                                    Text("\(presentation.typeLabel) · \(Int(thumb.size.width * 2)) × \(Int(thumb.size.height * 2))")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                } else {
                                    Text(presentation.typeLabel)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                Text("·")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Text(presentation.formattedDate)
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

                    Button(action: { onCopy() }) {
                        Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.system(size: 16))
                            .foregroundColor(isCopied ? .white : Color.primary.opacity(0.6))
                            .frame(width: 36, height: 36)
                            .background(isCopied ? Color.green : Color.secondary.opacity(0.1))
                            .clipShape(Circle())
                            .scaleEffect(isCopied ? 0.85 : 1.0)
                            .shadow(color: isCopied ? Color.green.opacity(0.5) : Color.clear,
                                    radius: isCopied ? 4 : 0)
                            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isCopied)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .background(
                        Group {
                            if let sIdx = shortcutIndex {
                                let keyEq = KeyEquivalent(Character(String(sIdx + 1)))
                                Button("") { onCopy() }
                                    .keyboardShortcut(keyEq, modifiers: .command)
                                    .opacity(0)
                            }
                        }
                    )
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isTutorialItem ? Color(nsColor: .windowBackgroundColor) : Color.clear)
                .contentShape(Rectangle())
                .offset(x: isTutorialItem ? demoSwipeOffset : 0)
            }
        }
        .onAppear {
            if isTutorialItem {
                startDemoAnimation()
            }
        }
        .onDisappear {
            demoTimer?.invalidate()
            demoTimer = nil
        }
        .onTapGesture {
            let now = Date()
            if now.timeIntervalSince(lastClickTime) < 0.28 {
                // Double-click: cancel pending expansion immediately so row layout never shifts
                pendingExpandWorkItem?.cancel()
                pendingExpandWorkItem = nil
                onPaste()
            } else {
                // Single-click: schedule ultra-fast 120ms expansion (2.5x faster than SwiftUI default delay)
                pendingExpandWorkItem?.cancel()
                let workItem = DispatchWorkItem {
                    onToggleExpand()
                }
                pendingExpandWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
            }
            lastClickTime = now
        }
        .onHover { hovering in
            // Only this row re-renders — ContentView is untouched
            isHovered = hovering
        }
        .listRowBackground(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
        .contextMenu {
            Button(action: {
                onCopy()
            }) {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button(action: {
                onTogglePin()
            }) {
                Label(item.pinned ? "Unpin" : "Pin", systemImage: item.pinned ? "pin.slash" : "pin")
            }

            Button(action: {
                isEditing = true
                isLoadingEdit = true
                DispatchQueue.global(qos: .userInitiated).async {
                    let full = loadFullText()
                    DispatchQueue.main.async {
                        editedText = full
                        isLoadingEdit = false
                    }
                }
            }) {
                Label("Edit", systemImage: "square.and.pencil")
            }

            Divider()

            Button(role: .destructive, action: {
                onDelete()
            }) {
                Label("Delete", systemImage: "trash")
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
                            onEdit(editedText)
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
            if !isTutorialItem || tutorialStep == .step6_delete {
                Button(role: .destructive) { onDelete() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !isTutorialItem || tutorialStep == .step1_pin {
                Button { onTogglePin() } label: {
                    Label(item.pinned ? "Unpin" : "Pin",
                          systemImage: item.pinned ? "pin.slash" : "pin")
                }
                .tint(.orange)
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowSeparatorTint(.clear)
    }

    // MARK: - Row animations
    private func startDemoAnimation() {
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: true) { _ in
            guard isTutorialItem else { return }
            if tutorialStep == .step1_pin {
                withAnimation(.easeInOut(duration: 0.55)) { demoSwipeOffset = 70 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(.easeInOut(duration: 0.4)) { demoSwipeOffset = 0 }
                }
            } else if tutorialStep == .step6_delete {
                withAnimation(.easeInOut(duration: 0.55)) { demoSwipeOffset = -70 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(.easeInOut(duration: 0.4)) { demoSwipeOffset = 0 }
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard isTutorialItem else { return }
            if tutorialStep == .step1_pin {
                withAnimation(.easeInOut(duration: 0.55)) { demoSwipeOffset = 70 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(.easeInOut(duration: 0.4)) { demoSwipeOffset = 0 }
                }
            } else if tutorialStep == .step6_delete {
                withAnimation(.easeInOut(duration: 0.55)) { demoSwipeOffset = -70 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(.easeInOut(duration: 0.4)) { demoSwipeOffset = 0 }
                }
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

    var isTutorialTarget: Bool {
        (filterType == "pinned" && manager.isTutorialActive && manager.tutorialStep == .step2_goToPinned) ||
        (manager.isTutorialActive && manager.tutorialStep == .step3_rightClickPill && manager.showPillHighlight)
    }

    var tutorialColor: Color {
        manager.tutorialStep == .step3_rightClickPill ? Color.teal : Color.orange
    }

    var body: some View {
        Button(action: {
            if isSelected {
                manager.activeFilters.remove(filterType)
            } else {
                manager.activeFilters.insert(filterType)
            }
            if manager.isTutorialActive && manager.tutorialStep == .step2_goToPinned && filterType == "pinned" {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    manager.tutorialStep = .step3_rightClickPill
                }
                manager.startStep3PillHighlightDelay()
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
            .background(isSelected ? Color.blue : (isFlashing ? Color.orange.opacity(0.9) : (isTutorialTarget ? tutorialColor.opacity(0.35) : Color.secondary.opacity(0.1))))
            .foregroundColor(isSelected || isFlashing ? .white : (isTutorialTarget ? tutorialColor : .primary))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isFlashing ? Color.orange : (isTutorialTarget ? tutorialColor : Color.secondary.opacity(0.2)), lineWidth: (isSelected || isFlashing || isTutorialTarget) ? (isTutorialTarget ? 1.5 : 0) : 1)
            )
            .scaleEffect(isFlashing || isTutorialTarget ? 1.12 : 1.0)
            .shadow(color: isFlashing || isTutorialTarget ? tutorialColor.opacity(0.6) : Color.clear, radius: isFlashing || isTutorialTarget ? 4 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isFlashing || isTutorialTarget)
        }
        .buttonStyle(PlainButtonStyle())
        .help("Right-click for mass actions")
        .contextMenu {
            let label = title ?? (filterType == "pinned" ? "Pinned" : "Items")
            let c = manager.filterCounts[filterType] ?? TypeCount()
            
            Group {
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
                    Label(filterType == "pinned" ? "Unpin All" : "Unpin All \(label) (\(c.pinned))", systemImage: "pin.slash")
                }
                
                Divider()
                
                Button(role: .destructive, action: {
                    var kept: [ClipItem] = []
                    for item in manager.history {
                        if filterType == "pinned" {
                            if !item.pinned { kept.append(item) }
                            else { LargePayloadStore.deletePayload(fileName: item.payloadFileName) }
                        } else {
                            if clipItemType(for: item) != filterType { kept.append(item) }
                            else { LargePayloadStore.deletePayload(fileName: item.payloadFileName) }
                        }
                    }
                    manager.history = kept
                    manager.saveHistory()
                }) {
                    Label("Delete All \(label) (\(c.total))", systemImage: "trash")
                }
            }
            .onAppear {
                if manager.isTutorialActive && manager.tutorialStep == .step3_rightClickPill {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        manager.tutorialStep = .step4_editClip
                    }
                }
            }
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var eventMonitor: Any?
    var timer: Timer?
    var previewWindow: NSWindow?
    let clipboardManager = ClipboardManager()
    let defaults = UserDefaults.standard
    var aboutWindow: NSWindow?
    var permissionsWindow: NSWindow?
    var permissionButtons: [NSButton] = []
    var permissionsTimer: Timer?
    var settingsMenu: NSMenu!
    var isMenuTracking = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if defaults.object(forKey: "hasLaunchedBefore") == nil {
            defaults.set(true, forKey: "hasLaunchedBefore")
            try? SMAppService.mainApp.register()
        }

        NSApp.setActivationPolicy(.accessory)

        let contentView = ContentView(manager: clipboardManager)
        popover = NSPopover()
        popover.contentSize = NSSize(width: 450, height: clipboardManager.menuHeight)
        popover.behavior = .applicationDefined
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

        checkAndPromptAccessibilityPermission()
        checkForUpdates(silentIfCurrent: true)

        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, !self.isMenuTracking else { return }
            self.closePopover()
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isMenuTracking = true
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.isMenuTracking = false
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover(statusItem.button)
        return true
    }

    func checkAndPromptAccessibilityPermission() {
        let key = "hasSeenPermissionsGuide_v1"
        let hasSeen = defaults.bool(forKey: key)
        if !hasSeen {
            defaults.set(true, forKey: key)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.showPermissionsGuide(isFirstLaunch: true)
            }
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
            
            // Force popover backdrop NSVisualEffectView state to .active and reset scroll position to top
            if let window = popover.contentViewController?.view.window {
                func forceActiveStateAndResetScroll(in view: NSView) {
                    if let vev = view as? NSVisualEffectView {
                        vev.state = .active
                    }
                    if let sv = view as? NSScrollView {
                        sv.contentView.scroll(to: NSPoint(x: 0, y: 0))
                        sv.reflectScrolledClipView(sv.contentView)
                    }
                    if let tv = view as? NSTableView {
                        tv.style = .plain
                        tv.intercellSpacing = NSSize(width: 0, height: 0)
                    }
                    for sub in view.subviews {
                        forceActiveStateAndResetScroll(in: sub)
                    }
                }
                if let root = window.contentView?.superview ?? window.contentView {
                    forceActiveStateAndResetScroll(in: root)
                }

                NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
                NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    guard let self = self, self.popover.isShown else { return }
                    if window.attachedSheet == nil && !self.isMenuTracking {
                        self.closePopover()
                    }
                }
            }

            if eventMonitor == nil {
                eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    guard let self = self, self.popover.isShown, !self.isMenuTracking else { return }
                    let mouseLoc = NSEvent.mouseLocation
                    if let popoverWindow = self.popover.contentViewController?.view.window {
                        if popoverWindow.frame.contains(mouseLoc) {
                            return
                        }
                    }
                    if let btn = self.statusItem.button, let btnWindow = btn.window {
                        if btnWindow.frame.contains(mouseLoc) {
                            return
                        }
                    }
                    self.closePopover()
                }
            }
        }
    }

    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
            popover.close()
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
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
        let limits = [100, 500, 1000, 5000, 10000]
        for limit in limits {
            let item = NSMenuItem(title: "\(limit) Items", action: #selector(setMaxItems(_:)), keyEquivalent: "")
            item.state = clipboardManager.maxHistorySize == limit ? .on : .off
            item.tag = limit
            item.target = self
            msub.addItem(item)
        }
        maxItems.submenu = msub
        menu.addItem(maxItems)

        let concealItem = NSMenuItem(title: "Skip sensitive copies", action: #selector(toggleConcealed), keyEquivalent: "")
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

        let tutorialItem = NSMenuItem(title: "Replay Interactive Tutorial...", action: #selector(replayTutorialAction), keyEquivalent: "")
        tutorialItem.image = icon("sparkles")
        tutorialItem.target = self
        menu.addItem(tutorialItem)

        let permItem = NSMenuItem(title: "Permissions & Settings...", action: #selector(showPermissionsAction), keyEquivalent: "")
        permItem.image = icon("hand.raised.square")
        permItem.target = self
        menu.addItem(permItem)

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

    @objc func replayTutorialAction() {
        clipboardManager.resetTutorial()
        showPopover(statusItem.button)
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

    @objc func manualUpdateCheck() {
        closePopover()
        checkForUpdates(silentIfCurrent: false)
    }
    @objc func quitApp() { NSApp.terminate(nil) }

func getAppLogoImage() -> NSImage {
    let candidates = [
        Bundle.main.path(forResource: "AppLogo", ofType: "png"),
        Bundle.main.path(forResource: "AppIcon", ofType: "png"),
        "/Applications/ClipLocal.app/Contents/Resources/AppLogo.png",
        "/Applications/ClipLocal.app/Contents/Resources/AppIcon.png",
        "AppLogo.png",
        "AppIcon.png",
        "/Users/arunthomas/ClipLocal/AppLogo.png",
        "/Users/arunthomas/ClipLocal/AppIcon.png"
    ].compactMap { $0 }
    for c in candidates {
        if let img = NSImage(contentsOfFile: c) { return img }
    }
    if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"), let img = NSImage(contentsOfFile: path) {
        return img
    }
    if let img = NSImage(named: "AppIcon") {
        return img
    }
    return NSApp.applicationIconImage ?? (NSImage(systemSymbolName: "paperclip.circle", accessibilityDescription: nil) ?? NSImage())
}

    @objc func showPermissionsAction() {
        showPermissionsGuide(isFirstLaunch: false)
    }

    func showPermissionsGuide(isFirstLaunch: Bool) {
        closePopover()
        if permissionsWindow != nil {
            permissionsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let width: CGFloat = 480
        let height: CGFloat = 460
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active

        // App Icon
        let icon = NSImageView(frame: NSRect(x: (width - 56)/2, y: 360, width: 56, height: 56))
        icon.image = getAppLogoImage()
        icon.imageScaling = .scaleProportionallyUpOrDown
        bg.addSubview(icon)

        // Title
        let title = NSTextField(labelWithString: "Permissions & Setup")
        title.font = NSFont.systemFont(ofSize: 21, weight: .bold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: 320, width: width, height: 28)
        bg.addSubview(title)

        // Subtitle
        let sub = NSTextField(labelWithString: "Enable accessibility and menu bar access for smooth clipboard management on macOS.")
        sub.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        sub.textColor = .secondaryLabelColor
        sub.alignment = .center
        sub.frame = NSRect(x: 20, y: 294, width: width - 40, height: 18)
        bg.addSubview(sub)

        struct PermItem {
            let symbol: String
            let color: NSColor
            let title: String
            let desc: String
            let action: Selector
        }

        let items: [PermItem] = [
            PermItem(
                symbol: "hand.point.up.left.fill",
                color: .systemPurple,
                title: "Accessibility (Recommended)",
                desc: "Enables instant double-click paste and global keyboard shortcuts.",
                action: #selector(openAccessibilitySettings)
            ),
            PermItem(
                symbol: "menubar.rectangle",
                color: .systemBlue,
                title: "Menu Bar Icon (macOS Tahoe+)",
                desc: "Keep ClipLocal visible in the top menu bar for fast access.",
                action: #selector(openMenuBarSettings)
            ),
            PermItem(
                symbol: "arrow.clockwise.circle.fill",
                color: .systemGreen,
                title: "Launch at Login (Optional)",
                desc: "Silently starts ClipLocal in the background on startup.",
                action: #selector(toggleLaunchAtLogin)
            )
        ]

        let rowHeight: CGFloat = 48
        let rowYPositions: [CGFloat] = [224, 158, 92]

        self.permissionButtons = []

        for (idx, item) in items.enumerated() {
            let rowY = rowYPositions[idx]

            // Icon
            let symView = NSImageView(frame: NSRect(x: 32, y: rowY + (rowHeight - 26)/2, width: 26, height: 26))
            let symCfg = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
            symView.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(symCfg)
            symView.contentTintColor = item.color
            bg.addSubview(symView)

            // Text
            let textWidth = width - 68 - 115
            let hLabel = NSTextField(labelWithString: item.title)
            hLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            hLabel.frame = NSRect(x: 68, y: rowY + 24, width: textWidth, height: 18)
            bg.addSubview(hLabel)

            let dLabel = NSTextField(labelWithString: item.desc)
            dLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
            dLabel.textColor = .secondaryLabelColor
            dLabel.lineBreakMode = .byTruncatingTail
            dLabel.frame = NSRect(x: 68, y: rowY + 4, width: textWidth, height: 18)
            bg.addSubview(dLabel)

            // Action Button
            let btn = NSButton(title: "Open", target: self, action: item.action)
            btn.frame = NSRect(x: width - 32 - 70, y: rowY + (rowHeight - 28)/2, width: 70, height: 28)
            btn.bezelStyle = .rounded
            btn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            bg.addSubview(btn)
            permissionButtons.append(btn)
        }

        // Done Button (Crisp contrast pill)
        let doneBtn = NSButton(title: "Done", target: self, action: #selector(closePermissionsGuide))
        doneBtn.frame = NSRect(x: (width - 150)/2, y: 26, width: 150, height: 36)
        doneBtn.isBordered = false
        doneBtn.wantsLayer = true
        doneBtn.layer?.backgroundColor = NSColor.white.cgColor
        doneBtn.layer?.cornerRadius = 18
        doneBtn.layer?.masksToBounds = true
        doneBtn.attributedTitle = NSAttributedString(string: "Done", attributes: [
            .foregroundColor: NSColor.black,
            .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        ])
        bg.addSubview(doneBtn)

        win.contentView = bg
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.permissionsWindow = win

        // Initial check and auto-polling timer for live updates
        checkPermissionsStatus()
        permissionsTimer?.invalidate()
        let t = Timer(timeInterval: 0.8, target: self, selector: #selector(checkPermissionsStatus), userInfo: nil, repeats: true)
        RunLoop.current.add(t, forMode: .common)
        self.permissionsTimer = t
    }

    @objc func checkPermissionsStatus() {
        guard permissionsWindow != nil, permissionButtons.count >= 3 else { return }

        // Row 0: Accessibility
        let axOk = AXIsProcessTrusted()
        updatePermissionButton(permissionButtons[0], isGranted: axOk)

        // Row 1: Menu Bar Icon
        let menuBarOk = (statusItem != nil)
        updatePermissionButton(permissionButtons[1], isGranted: menuBarOk)

        // Row 2: Launch at Login
        let loginOk = (SMAppService.mainApp.status == .enabled)
        updatePermissionButton(permissionButtons[2], isGranted: loginOk)
    }

    func updatePermissionButton(_ btn: NSButton, isGranted: Bool) {
        if isGranted {
            if btn.title != "✓" {
                btn.title = "✓"
                btn.font = NSFont.systemFont(ofSize: 13, weight: .bold)
                btn.contentTintColor = .systemGreen
                btn.toolTip = "Granted (Click to open settings)"
            }
        } else {
            if btn.title != "Open" {
                btn.title = "Open"
                btn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
                btn.contentTintColor = nil
                btn.toolTip = "Click to open settings"
            }
        }
    }

    @objc func closePermissionsGuide() {
        permissionsTimer?.invalidate()
        permissionsTimer = nil
        permissionButtons = []
        defaults.set(true, forKey: "hasSeenPermissionsGuide_v1")
        permissionsWindow?.close()
        permissionsWindow = nil
        showPopover(statusItem.button)
    }

    @objc func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.checkPermissionsStatus()
        }
    }

    @objc func openMenuBarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        if service.status == .enabled {
            try? service.unregister()
        } else {
            try? service.register()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.checkPermissionsStatus()
        }
    }

    // MARK: - About window (privacy-first splash)

    @objc func showAboutMenu() { showAbout(onLaunch: false) }

    func showAbout(onLaunch: Bool = false) {
        closePopover()
        if onLaunch && defaults.bool(forKey: "hideAbout") { return }

        if aboutWindow != nil {
            aboutWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        struct AboutFeature {
            let symbol: String
            let color: NSColor
            let title: String
            let desc: String
        }

        let features: [AboutFeature] = [
            AboutFeature(symbol: "lock.shield.fill", color: .systemPurple, title: "100% On-Device & Private", desc: "Your clipboard data never leaves your Mac. No cloud, no tracking, no accounts."),
            AboutFeature(symbol: "doc.on.clipboard.fill", color: .systemBlue, title: "Double-Click Direct Paste", desc: "Double-click any clip item to instantly paste it directly where your active cursor is."),
            AboutFeature(symbol: "key.fill", color: .systemOrange, title: "Skips Sensitive Copies", desc: "By default, sensitive and concealed copies from password managers are completely ignored."),
            AboutFeature(symbol: "eye.slash.fill", color: .systemTeal, title: "Zero Telemetry", desc: "No analytics or data collection. Only connects to GitHub manually when checking updates."),
            AboutFeature(symbol: "lock.fill", color: .systemGreen, title: "Keychain & Encrypted Storage", desc: "Hardware-backed AES-256 GCM encryption via Apple Keychain with secure 0600 on-disk fallback."),
            AboutFeature(symbol: "chevron.left.forwardslash.chevron.right", color: .systemPink, title: "Free & Open Source", desc: "ClipLocal is completely free and open source. Check out the code on GitHub.")
        ]

        let width: CGFloat = 460
        let textWidth: CGFloat = width - 115
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        let textFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

        var featureHeights: [CGFloat] = []
        var totalFeaturesHeight: CGFloat = 0
        for f in features {
            let attr = NSAttributedString(string: f.desc, attributes: [
                .font: textFont,
                .paragraphStyle: para
            ])
            let measured = attr.boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            let h = ceil(measured.height) + 24 // title height + spacing
            featureHeights.append(h)
            totalFeaturesHeight += h + 16 // gap between feature items
        }
        totalFeaturesHeight -= 16 // remove last item gap

        let headerHeight: CGFloat = 204
        let bottomSpaceNeeded: CGFloat = 124 // 28px gap + 16px credit + 20px gap + 34px buttons + 26px bottom padding
        let finalHeight = headerHeight + totalFeaturesHeight + bottomSpaceNeeded

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: finalHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.center()
        win.isReleasedWhenClosed = false
        win.level = .floating

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: finalHeight))
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        
        let icon = NSImageView(frame: NSRect(x: (width - 64)/2, y: finalHeight - 88, width: 64, height: 64))
        icon.image = getAppLogoImage()
        icon.imageScaling = .scaleProportionallyUpOrDown
        bg.addSubview(icon)

        let title = NSTextField(labelWithString: "ClipLocal")
        title.font = NSFont.systemFont(ofSize: 24, weight: .bold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: finalHeight - 124, width: width, height: 28)
        bg.addSubview(title)

        let ver = NSTextField(labelWithString: "Version \(appVersion)")
        ver.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        ver.textColor = .tertiaryLabelColor
        ver.alignment = .center
        ver.frame = NSRect(x: 0, y: finalHeight - 144, width: width, height: 15)
        bg.addSubview(ver)
        
        let sub = NSTextField(labelWithString: "Your clipboard. Yours alone.")
        sub.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        sub.textColor = .secondaryLabelColor
        sub.alignment = .center
        sub.frame = NSRect(x: 16, y: finalHeight - 168, width: width - 32, height: 16)
        bg.addSubview(sub)

        var currentY = finalHeight - headerHeight
        for (i, f) in features.enumerated() {
            let itemH = featureHeights[i]
            let itemY = currentY - itemH

            let symSize: CGFloat = 24
            let symView = NSImageView(frame: NSRect(x: 36, y: itemY + (itemH - symSize)/2 + 2, width: symSize, height: symSize))
            let symCfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            symView.image = NSImage(systemSymbolName: f.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(symCfg)
            symView.contentTintColor = f.color
            bg.addSubview(symView)

            let titleLabel = NSTextField(labelWithString: f.title)
            titleLabel.frame = NSRect(x: 74, y: itemY + itemH - 20, width: textWidth, height: 18)
            titleLabel.font = titleFont
            titleLabel.textColor = .labelColor
            titleLabel.isEditable = false
            titleLabel.drawsBackground = false
            titleLabel.isBordered = false
            bg.addSubview(titleLabel)

            let attr = NSAttributedString(string: f.desc, attributes: [
                .font: textFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: para
            ])
            let descLabel = NSTextField(labelWithAttributedString: attr)
            descLabel.frame = NSRect(x: 74, y: itemY, width: textWidth, height: itemH - 22)
            descLabel.lineBreakMode = .byWordWrapping
            descLabel.maximumNumberOfLines = 0
            descLabel.isEditable = false
            descLabel.drawsBackground = false
            descLabel.isBordered = false
            bg.addSubview(descLabel)

            currentY = itemY - 16
        }

        // Author Note (Spacious gap below features)
        let credit = NSTextField(labelWithString: "Built by Arun Thomas")
        credit.frame = NSRect(x: 0, y: 78, width: width, height: 16)
        credit.alignment = .center
        credit.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        credit.textColor = .secondaryLabelColor
        bg.addSubview(credit)

        // Action Buttons (Exact 26px bottom padding)
        let buttonsY: CGFloat = 26
        let contactW: CGFloat = 105
        let gitW: CGFloat = 105
        let closeW: CGFloat = 125
        let spacing: CGFloat = 14
        let totalW = contactW + gitW + closeW + (2 * spacing)
        let startX = (width - totalW) / 2
        
        let contact = NSButton(title: "Contact", target: self, action: #selector(contactDeveloper))
        contact.frame = NSRect(x: startX, y: buttonsY, width: contactW, height: 34)
        contact.isBordered = false
        contact.wantsLayer = true
        contact.layer?.backgroundColor = NSColor.white.cgColor
        contact.layer?.cornerRadius = 17
        contact.layer?.masksToBounds = true
        contact.attributedTitle = NSAttributedString(string: "Contact", attributes: [
            .foregroundColor: NSColor.black,
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium)
        ])
        bg.addSubview(contact)

        let github = NSButton(title: "GitHub", target: self, action: #selector(openGitHub))
        github.frame = NSRect(x: startX + contactW + spacing, y: buttonsY, width: gitW, height: 34)
        github.isBordered = false
        github.wantsLayer = true
        github.layer?.backgroundColor = NSColor.black.cgColor
        github.layer?.cornerRadius = 17
        github.layer?.masksToBounds = true
        github.attributedTitle = NSAttributedString(string: "GitHub", attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium)
        ])
        bg.addSubview(github)

        let close = NSButton(title: "Get Started", target: self, action: #selector(closeAbout))
        close.frame = NSRect(x: startX + contactW + spacing + gitW + spacing, y: buttonsY, width: closeW, height: 34)
        close.isBordered = false
        close.wantsLayer = true
        close.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        close.layer?.cornerRadius = 17
        close.layer?.masksToBounds = true
        close.keyEquivalent = "\r"
        close.attributedTitle = NSAttributedString(string: "Get Started", attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium)
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
        let currentChangeCount = pb.changeCount
        if currentChangeCount == clipboardManager.lastChangeCount { return }
        clipboardManager.lastChangeCount = currentChangeCount

        let sourceApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let pb = NSPasteboard.general
            
            if self.clipboardManager.skipConcealed {
                if let types = pb.types, types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) {
                    return
                }
            }

            var newText: String?
            var newImageData: Data?
            var newPayloadFileName: String?

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
    }

struct VisualEffectHUDView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.state = .active
        view.blendingMode = .withinWindow
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct ToastHUDView: View {
    let snippet: String
    let color: NSColor?
    
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let color = color {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: color))
                    .frame(width: 22, height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
                    )
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("✓ Copied")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                
                Text(snippet)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 320)
        .background(VisualEffectHUDView())
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(NSColor.separatorColor).opacity(0.35), lineWidth: 1)
        )
    }
}

    func showPreview(_ text: String) {
        previewWindow?.close()
        let snippet = String(text.prefix(90)).replacingOccurrences(of: "\n", with: " ")
        let width: CGFloat = 320
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let parsedColor = ColorParser.parse(text)

        let hostingView = NSHostingView(rootView: ToastHUDView(snippet: snippet, color: parsedColor))
        let height = max(44, hostingView.fittingSize.height)
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
        win.contentView = hostingView
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

struct ChangelogAlertView: View {
    let changelog: String
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 6) {
                Text(changelog)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Color(NSColor.labelColor))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
        .frame(width: 360, height: 150)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 1)
        )
    }
}

func createChangelogView(changelog: String) -> NSView {
    let hostingView = NSHostingView(rootView: ChangelogAlertView(changelog: changelog))
    hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 150)
    return hostingView
}

    func showUpdateResult(_ remote: String?, changelog: String, newer: Bool, downloadURL: String = downloadPageURL) {
        closePopover()
        let alert = NSAlert()
        NSApp.activate(ignoringOtherApps: true)
        if newer, let remote = remote {
            alert.messageText = "ClipLocal \(remote) is available"
            alert.informativeText = "You have v\(appVersion). Here's what's new:"
            if !changelog.isEmpty {
                alert.accessoryView = createChangelogView(changelog: changelog)
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
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        clipboardManager.expandedIdx.removeAll()
    }
}

// MARK: - App Main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
