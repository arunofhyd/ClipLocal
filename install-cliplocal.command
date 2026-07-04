#!/bin/bash
# =============================================================================
#  ClipLocal — Builder & Installer
#  Built by Arun Thomas · https://github.com/arunofhyd/ClipLocal
#
#  This downloads the ClipLocal source, builds it LOCALLY on your Mac, and
#  installs it to your Applications folder. Because it's built on your own
#  machine, macOS trusts it — no "unidentified developer" block.
# =============================================================================

APP_NAME="ClipLocal"
REPO_RAW="https://raw.githubusercontent.com/arunofhyd/ClipLocal/main"

# ---- Clean, tasteful terminal styling ------------------------------------
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
BLUE='\033[38;5;39m'; GREEN='\033[38;5;35m'; YELLOW='\033[38;5;220m'; RED='\033[38;5;196m'; GREY='\033[38;5;245m'

line() { printf "${DIM}────────────────────────────────────────────────────────────${NC}\n"; }
step() { printf "${BLUE}${BOLD}▸${NC} ${BOLD}%s${NC}\n" "$1"; }
ok()   { printf "  ${GREEN}✓${NC} %s\n" "$1"; }
warn() { printf "  ${YELLOW}!${NC} %s\n" "$1"; }
fail() { printf "  ${RED}✗ %s${NC}\n" "$1"; }

clear
printf "\n"
printf "${BLUE}${BOLD}   ClipLocal${NC}\n"
printf "${GREY}   Your clipboard. Yours alone.${NC}\n"
printf "${GREY}   Built by Arun Thomas${NC}\n\n"
line
printf "\n"

# ---- Step 1: Command Line Tools (compiler) -------------------------------
step "Checking for build tools…"
if ! xcode-select -p >/dev/null 2>&1; then
    warn "Apple's Command Line Tools are needed to build the app."
    printf "  ${GREY}A small official Apple installer will pop up. Please click ${BOLD}Install${NC}${GREY} and wait for it to finish.${NC}\n\n"
    xcode-select --install >/dev/null 2>&1
    printf "  ${YELLOW}When the installation is COMPLETE, press [Enter] here to continue…${NC}"
    read -r
    if ! xcode-select -p >/dev/null 2>&1; then
        fail "Build tools still not found."
        printf "  ${GREY}Please finish the Apple installer, then run this file again.${NC}\n\n"
        exit 1
    fi
fi
ok "Build tools ready."
printf "\n"

# ---- Step 2: Workspace ----------------------------------------------------
step "Preparing a clean workspace…"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
cd "$BUILD_DIR" || { fail "Could not create workspace."; exit 1; }
ok "Workspace ready."
printf "\n"

# ---- Step 3: Download the source -----------------------------------------
step "Downloading ClipLocal source…"
if ! curl -fsSL "$REPO_RAW/main.swift" -o main.swift; then
    fail "Could not download the app source."
    printf "  ${GREY}Check your internet connection and try again.${NC}\n\n"
    exit 1
fi
ok "Source downloaded."
printf "\n"

# ---- Step 4: Generate the app icon (blue lock-on-document) ---------------
step "Creating the app icon…"
cat > MakeIcon.swift <<'ICONEOF'
import Cocoa

let px: CGFloat = 1024
let img = NSImage(size: NSSize(width: px, height: px))
img.lockFocus()

// Apple-blue rounded-rect background with a subtle vertical gradient.
let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: px, height: px),
                      xRadius: 230, yRadius: 230)
bg.addClip()
let top = NSColor(calibratedRed: 0.16, green: 0.55, blue: 1.00, alpha: 1.0)
let bot = NSColor(calibratedRed: 0.00, green: 0.40, blue: 0.95, alpha: 1.0)
NSGradient(starting: top, ending: bot)?.draw(in: NSRect(x: 0, y: 0, width: px, height: px), angle: -90)

// White lock-on-document glyph, centered.
let cfg = NSImage.SymbolConfiguration(pointSize: 560, weight: .regular)
if let sym = NSImage(systemSymbolName: "lock.doc.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
    let s = sym.size
    let tinted = NSImage(size: s)
    tinted.lockFocus()
    sym.draw(in: NSRect(origin: .zero, size: s))
    NSColor.white.set()
    NSRect(origin: .zero, size: s).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let rect = NSRect(x: (px - s.width)/2, y: (px - s.height)/2, width: s.width, height: s.height)
    tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
}

img.unlockFocus()
if let tiff = img.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: "AppIcon.png"))
}
ICONEOF

swiftc MakeIcon.swift -o MakeIcon >/dev/null 2>&1 && ./MakeIcon
if [ -f AppIcon.png ]; then
    mkdir -p AppIcon.iconset
    for pair in "16 16" "32 16@2x" "32 32" "64 32@2x" "128 128" "256 128@2x" "256 256" "512 256@2x" "512 512" "1024 512@2x"; do
        set -- $pair
        sips -z "$1" "$1" AppIcon.png --out "AppIcon.iconset/icon_${2}.png" >/dev/null 2>&1
    done
    iconutil -c icns AppIcon.iconset >/dev/null 2>&1
    ok "Icon created."
else
    warn "Icon generation skipped (app will still work)."
fi
printf "\n"

# ---- Step 5: Assemble the app bundle -------------------------------------
step "Building ${APP_NAME}.app…"
APP="$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>com.local.cliplocal</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

if ! swiftc -O -o "$APP/Contents/MacOS/$APP_NAME" main.swift -framework Cocoa 2>build_errors.txt; then
    fail "Compilation failed."
    printf "${GREY}"; cat build_errors.txt; printf "${NC}\n"
    exit 1
fi
chmod +x "$APP/Contents/MacOS/$APP_NAME"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
ok "App built."
printf "\n"

# ---- Step 6: Build the drag-to-Applications installer window -------------
step "Preparing installer window…"

# If it's already running, quit it so a fresh copy can replace it later.
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cat > Installer.swift <<'INSTEOF'
import Cocoa
import QuartzCore

let appName = "ClipLocal"
let sourcePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""

// Icon you can drag.
class DragIcon: NSImageView, NSDraggingSource {
    var fileURL: URL?
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
    override func mouseDown(with event: NSEvent) {
        guard let url = fileURL else { return }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        let drag = NSDraggingItem(pasteboardWriter: item)
        drag.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [drag], event: event, source: self)
    }
}

// The Applications folder drop target.
class DropZone: NSImageView {
    override init(frame f: NSRect) { super.init(frame: f); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { super.init(coder: coder); registerForDraggedTypes([.fileURL]) }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard let str = s.draggingPasteboard.propertyList(forType: .fileURL) as? String,
              let src = URL(string: str) else { return false }
        let dest = URL(fileURLWithPath: "/Applications").appendingPathComponent(src.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: src, to: dest)
        } catch {
            // Needs admin — fall back to an authenticated copy.
            let p = src.path.replacingOccurrences(of: "'", with: "'\\''")
            let script = "do shell script \"rm -rf '/Applications/\(appName).app'; cp -R '\(p)' /Applications/\" with administrator privileges"
            if let s = NSAppleScript(source: script) {
                var err: NSDictionary?
                s.executeAndReturnError(&err)
                if err != nil {
                    let a = NSAlert(); a.messageText = "Installation failed"
                    a.informativeText = "Could not copy into Applications."
                    a.runModal(); return false
                }
            }
        }
        try? (dest as NSURL).setResourceValue(false, forKey: .isExcludedFromBackupKey)
        let clean = Process()
        clean.launchPath = "/usr/bin/xattr"
        clean.arguments = ["-dr", "com.apple.quarantine", dest.path]
        try? clean.run(); clean.waitUntilExit()

        NSSound(named: "Glass")?.play()
        let a = NSAlert()
        a.messageText = "ClipLocal installed!"
        a.informativeText = "Look for the clipboard icon in your menu bar (top-right). It runs quietly with no Dock icon."
        a.addButton(withTitle: "Launch ClipLocal")
        a.addButton(withTitle: "Quit")
        if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(dest) }
        NSApp.terminate(nil)
        return true
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let W: CGFloat = 620, H: CGFloat = 380
let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
win.title = "Install ClipLocal"
win.center()

let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: W, height: H))
bg.material = .windowBackground; bg.state = .active
win.contentView = bg

let title = NSTextField(labelWithString: "Install ClipLocal")
title.frame = NSRect(x: 0, y: H - 70, width: W, height: 30)
title.alignment = .center
title.font = NSFont.systemFont(ofSize: 22, weight: .bold)
bg.addSubview(title)

let sub = NSTextField(labelWithString: "Drag the ClipLocal icon onto the Applications folder")
sub.frame = NSRect(x: 0, y: H - 96, width: W, height: 20)
sub.alignment = .center
sub.font = NSFont.systemFont(ofSize: 13)
sub.textColor = .secondaryLabelColor
bg.addSubview(sub)

let iconSize: CGFloat = 128
let midY = (H - iconSize) / 2 - 10

// App icon (draggable)
let appIcon = DragIcon(frame: NSRect(x: 90, y: midY, width: iconSize, height: iconSize))
appIcon.imageScaling = .scaleProportionallyUpOrDown
appIcon.image = NSWorkspace.shared.icon(forFile: sourcePath)
appIcon.fileURL = URL(fileURLWithPath: sourcePath)
bg.addSubview(appIcon)

let appLabel = NSTextField(labelWithString: appName)
appLabel.frame = NSRect(x: 90, y: midY - 26, width: iconSize, height: 18)
appLabel.alignment = .center
appLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
bg.addSubview(appLabel)

// Arrow
let arrow = NSTextField(labelWithString: "→")
arrow.frame = NSRect(x: (W - 40)/2, y: midY + iconSize/2 - 24, width: 40, height: 40)
arrow.alignment = .center
arrow.font = NSFont.systemFont(ofSize: 34, weight: .thin)
arrow.textColor = .tertiaryLabelColor
bg.addSubview(arrow)

// Applications folder (drop zone)
let drop = DropZone(frame: NSRect(x: W - 90 - iconSize, y: midY, width: iconSize, height: iconSize))
drop.imageScaling = .scaleProportionallyUpOrDown
drop.image = NSWorkspace.shared.icon(forFile: "/Applications")
bg.addSubview(drop)

let appsLabel = NSTextField(labelWithString: "Applications")
appsLabel.frame = NSRect(x: W - 90 - iconSize, y: midY - 26, width: iconSize, height: 18)
appsLabel.alignment = .center
appsLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
bg.addSubview(appsLabel)

win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
INSTEOF

if ! swiftc -O -o Installer Installer.swift -framework Cocoa >/dev/null 2>&1; then
    # Fall back to plain auto-copy if the installer window can't build.
    warn "Using direct install…"
    DEST="/Applications/$APP_NAME.app"
    if [ -w "/Applications" ]; then rm -rf "$DEST"; cp -R "$APP" "$DEST"
    else osascript -e "do shell script \"rm -rf '$DEST'; cp -R '$BUILD_DIR/$APP' '/Applications/'\" with administrator privileges" >/dev/null 2>&1; fi
    xattr -dr com.apple.quarantine "$DEST" >/dev/null 2>&1 || true
    ok "Installed to Applications."
    printf "\n"; line
    printf "\n  ${GREEN}${BOLD}✓ ClipLocal is installed!${NC}\n\n"
    printf "  ${GREY}Look for the clipboard icon in your menu bar (top-right).${NC}\n\n"
    printf "  Launch ClipLocal now? [Y/n] "
    read -r ans
    case "$ans" in [Nn]*) : ;; *) open "$DEST" ;; esac
    printf "\n"
    exit 0
fi
ok "Installer ready."
printf "\n"

line
printf "\n  ${GREEN}${BOLD}✓ Build complete!${NC}\n\n"
printf "  ${GREY}A window will open — drag the ClipLocal icon onto the${NC}\n"
printf "  ${GREY}Applications folder to finish installing.${NC}\n\n"

# Launch the drag-install window (blocks until the user finishes).
./Installer "$BUILD_DIR/$APP"
printf "\n"
