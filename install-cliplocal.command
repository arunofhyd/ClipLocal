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
    while ! xcode-select -p >/dev/null 2>&1; do
        printf "  ${GREY}Waiting for Command Line Tools installation to finish…${NC}\n"
        sleep 5
    done
fi

# ---- Workaround for CLT "redefinition of module 'SwiftBridging'" bug ------
# Some CLT versions (notably 16.x on macOS 15) ship both module.modulemap and
# bridging.modulemap in /Library/Developer/CommandLineTools/usr/include/swift/,
# and both define 'module SwiftBridging', which makes Foundation/Cocoa fail.
_CLT_SWIFT="/Library/Developer/CommandLineTools/usr/include/swift"
_CLT_MODMAP="$_CLT_SWIFT/module.modulemap"
_CLT_BRIDGE="$_CLT_SWIFT/bridging.modulemap"

_NEED_BRIDGING_FIX=false
if [ -f "$_CLT_MODMAP" ] && [ -f "$_CLT_BRIDGE" ] && \
   grep -q "module SwiftBridging" "$_CLT_MODMAP" 2>/dev/null && \
   grep -q "module SwiftBridging" "$_CLT_BRIDGE" 2>/dev/null; then
    _NEED_BRIDGING_FIX=true
fi

if [ "$_NEED_BRIDGING_FIX" = true ]; then
    warn "Known compiler bug detected (SwiftBridging module conflict)."

    # Strategy 1: If ANY Xcode.app exists, use its toolchain for this build
    #             via DEVELOPER_DIR (per-process only — no system-wide changes).
    #             Check for Toolchains/XcodeDefault.xctoolchain — this is the
    #             reliable indicator of a valid Xcode developer directory.
    #             (swiftc lives in Toolchains/, NOT in usr/bin/ inside Xcode.app)
    _XCODE_DEV=""
    for _candidate in \
        "/Applications/Xcode.app/Contents/Developer" \
        "/Applications/Xcode-beta.app/Contents/Developer" \
        "/Applications/Xcode_*.app/Contents/Developer"; do
        # shellcheck disable=SC2086
        for _path in $_candidate; do
            if [ -d "$_path/Toolchains/XcodeDefault.xctoolchain" ]; then
                _XCODE_DEV="$_path"
                break 2
            fi
        done
    done

    if [ -n "$_XCODE_DEV" ]; then
        printf "  ${GREY}Using Xcode toolchain at ${_XCODE_DEV}${NC}\n"
        export DEVELOPER_DIR="$_XCODE_DEV"
    else
        # Strategy 2: No Xcode — surgically remove ONLY the duplicate SwiftBridging
        #             block from module.modulemap. We do NOT rename the whole file
        #             because it may contain other module definitions we must keep.
        #             bridging.modulemap already has the correct definition.
        printf "  ${GREY}No Xcode installation found. Attempting one-time compiler repair…${NC}\n"
        printf "  ${YELLOW}Your admin password may be required:${NC}\n"

        # Build a patched copy with only the SwiftBridging block removed.
        _PATCHED="/tmp/module.modulemap.patched"
        python3 -c "
import re, sys
try:
    with open('$_CLT_MODMAP', 'r') as f:
        content = f.read()
    # Remove the 'module SwiftBridging { ... }' block (single-level braces only)
    patched = re.sub(r'module\s+SwiftBridging\s*\{[^}]*\}', '', content)
    with open('$_PATCHED', 'w') as f:
        f.write(patched)
    sys.exit(0)
except Exception as e:
    sys.exit(1)
" 2>/dev/null

        if [ -f "$_PATCHED" ]; then
            if sudo cp "$_CLT_MODMAP" "${_CLT_MODMAP}.bak" 2>/dev/null && \
               sudo cp "$_PATCHED"    "$_CLT_MODMAP"        2>/dev/null; then
                ok "Compiler repaired (removed duplicate SwiftBridging from module.modulemap)."
            else
                fail "Could not auto-repair (sudo required). Please run this manually, then re-run this installer:"
                printf "\n"
                printf "  ${BOLD}  sudo cp '$_CLT_MODMAP' '${_CLT_MODMAP}.bak'${NC}\n"
                printf "  ${BOLD}  sudo cp '$_PATCHED' '$_CLT_MODMAP'${NC}\n\n"
                printf "  ${GREY}Or reinstall Command Line Tools cleanly:${NC}\n"
                printf "  ${BOLD}  sudo rm -rf /Library/Developer/CommandLineTools${NC}\n"
                printf "  ${BOLD}  xcode-select --install${NC}\n\n"
                exit 1
            fi
        else
            fail "Could not prepare patch. Please reinstall Command Line Tools:"
            printf "  ${BOLD}  sudo rm -rf /Library/Developer/CommandLineTools${NC}\n"
            printf "  ${BOLD}  xcode-select --install${NC}\n\n"
            exit 1
        fi
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
if ! curl -fsSL "$REPO_RAW/main.swift?v=$(date +%s)" -o main.swift; then
    fail "Could not download the app source."
    printf "  ${GREY}Check your internet connection and try again.${NC}\n\n"
    exit 1
fi
curl -fsSL "$REPO_RAW/version.json?v=$(date +%s)" -o version.json 2>/dev/null || true
ok "Source downloaded."
printf "\n"

# ---- Step 4: Generate the app icon (blue lock-on-document) ---------------
step "Creating the app icon…"
cat > MakeIcon.swift <<'ICONEOF'
import Cocoa

let px: CGFloat = 1024
let img = NSImage(size: NSSize(width: px, height: px))
img.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

// macOS icon padding: bounding box is typically ~824x824 inside a 1024 canvas
let padding: CGFloat = 100
let size = px - 2 * padding
ctx.translateBy(x: padding, y: padding)

// Scale up to use 120x120 SVG coordinate space, flipped for standard SVG rendering
let scale = size / 120.0
ctx.scaleBy(x: scale, y: scale)
ctx.translateBy(x: 0, y: 120)
ctx.scaleBy(x: 1, y: -1)

// Background
let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 120, height: 120), cornerWidth: 27, cornerHeight: 27, transform: nil)
ctx.addPath(bgPath)
ctx.clip()

let top = NSColor(calibratedRed: 0.16, green: 0.55, blue: 1.00, alpha: 1.0)
let bot = NSColor(calibratedRed: 0.00, green: 0.40, blue: 0.95, alpha: 1.0)
if let bgGrad = NSGradient(starting: top, ending: bot) {
    bgGrad.draw(from: NSPoint(x: 0, y: 0), to: NSPoint(x: 0, y: 120), options: [])
}

// Inner shine
ctx.saveGState()
let shinePath = CGPath(roundedRect: CGRect(x: 1, y: 1, width: 118, height: 118), cornerWidth: 26, cornerHeight: 26, transform: nil)
ctx.addPath(shinePath)
ctx.setLineWidth(2)
ctx.replacePathWithStrokedPath()
ctx.clip()
let shine0 = NSColor(white: 1.0, alpha: 0.6)
let shine1 = NSColor(white: 1.0, alpha: 0.0)
if let shineGrad = NSGradient(colors: [shine0, shine1, shine1, shine0], atLocations: [0.0, 0.3, 0.7, 1.0], colorSpace: .deviceRGB) {
    shineGrad.draw(in: NSRect(x: 0, y: 0, width: 120, height: 120), angle: 45)
}
ctx.restoreGState()

// Outer circle
ctx.saveGState()
let circlePath = CGPath(ellipseIn: CGRect(x: 18, y: 18, width: 84, height: 84), transform: nil)
ctx.addPath(circlePath)
ctx.setLineWidth(4)
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.strokePath()
ctx.restoreGState()

// Paperclip
ctx.saveGState()
ctx.translateBy(x: 60, y: 60)
ctx.rotate(by: 45 * .pi / 180) // 45 deg clockwise
ctx.scaleBy(x: 0.7, y: 0.7)
ctx.translateBy(x: -60, y: -60)

let p = CGMutablePath()
p.move(to: CGPoint(x: 54, y: 50))
p.addLine(to: CGPoint(x: 54, y: 70))
p.addArc(tangent1End: CGPoint(x: 54, y: 76), tangent2End: CGPoint(x: 60, y: 76), radius: 6)
p.addArc(tangent1End: CGPoint(x: 66, y: 76), tangent2End: CGPoint(x: 66, y: 70), radius: 6)
p.addLine(to: CGPoint(x: 66, y: 42))
p.addArc(tangent1End: CGPoint(x: 66, y: 32), tangent2End: CGPoint(x: 56, y: 32), radius: 10)
p.addArc(tangent1End: CGPoint(x: 46, y: 32), tangent2End: CGPoint(x: 46, y: 42), radius: 10)
p.addLine(to: CGPoint(x: 46, y: 74))
p.addArc(tangent1End: CGPoint(x: 46, y: 88), tangent2End: CGPoint(x: 60, y: 88), radius: 14)
p.addArc(tangent1End: CGPoint(x: 74, y: 88), tangent2End: CGPoint(x: 74, y: 74), radius: 14)
p.addLine(to: CGPoint(x: 74, y: 46))

ctx.addPath(p)
ctx.setLineWidth(5.5)
ctx.setLineCap(.round)
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.strokePath()
ctx.restoreGState()

img.unlockFocus()
if let tiff = img.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: "AppIcon.png"))
}
ICONEOF

SWIFT_SDK=$(xcrun --show-sdk-path 2>/dev/null)
SWIFT_CACHE="$BUILD_DIR/.swiftcache"
xcrun swiftc ${SWIFT_SDK:+-sdk "$SWIFT_SDK"} -module-cache-path "$SWIFT_CACHE" MakeIcon.swift -o MakeIcon > /dev/null 2>&1 && ./MakeIcon
if [ -f AppIcon.png ]; then
    mkdir -p AppIcon.iconset
    sips -z 16 16     AppIcon.png --out AppIcon.iconset/icon_16x16.png >/dev/null 2>&1
    sips -z 32 32     AppIcon.png --out AppIcon.iconset/icon_16x16@2x.png >/dev/null 2>&1
    sips -z 32 32     AppIcon.png --out AppIcon.iconset/icon_32x32.png >/dev/null 2>&1
    sips -z 64 64     AppIcon.png --out AppIcon.iconset/icon_32x32@2x.png >/dev/null 2>&1
    sips -z 128 128   AppIcon.png --out AppIcon.iconset/icon_128x128.png >/dev/null 2>&1
    sips -z 256 256   AppIcon.png --out AppIcon.iconset/icon_128x128@2x.png >/dev/null 2>&1
    sips -z 256 256   AppIcon.png --out AppIcon.iconset/icon_256x256.png >/dev/null 2>&1
    sips -z 512 512   AppIcon.png --out AppIcon.iconset/icon_256x256@2x.png >/dev/null 2>&1
    sips -z 512 512   AppIcon.png --out AppIcon.iconset/icon_512x512.png >/dev/null 2>&1
    sips -z 1024 1024 AppIcon.png --out AppIcon.iconset/icon_512x512@2x.png >/dev/null 2>&1
    iconutil -c icns AppIcon.iconset -o AppIcon.icns >/dev/null 2>&1
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
[ -f AppLogo.png ]  && cp AppLogo.png  "$APP/Contents/Resources/"
[ -f AppIcon.png ]  && cp AppIcon.png  "$APP/Contents/Resources/"
[ -f logo.svg ]     && cp logo.svg     "$APP/Contents/Resources/"

APP_VERSION=""
if [ -f version.json ]; then
    APP_VERSION=$(python3 -c "import json; print(json.load(open('version.json'))['version'])" 2>/dev/null || true)
fi
if [ -z "$APP_VERSION" ]; then
    APP_VERSION=$(grep -m1 'appVersion' main.swift 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
fi
if [ -z "$APP_VERSION" ]; then APP_VERSION="1.3.14"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>com.aoh.cliplocal</string>
  <key>CFBundleVersion</key><string>$APP_VERSION</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

if ! xcrun swiftc -O ${SWIFT_SDK:+-sdk "$SWIFT_SDK"} -module-cache-path "$SWIFT_CACHE" -o "$APP/Contents/MacOS/$APP_NAME" main.swift -framework Cocoa 2>build_errors.txt; then
    fail "Compilation failed."
    printf "${GREY}"; cat build_errors.txt; printf "${NC}\n"
    exit 1
fi
chmod +x "$APP/Contents/MacOS/$APP_NAME"
codesign --force --deep --sign - --requirements '=designated => identifier "com.aoh.cliplocal"' "$APP" >/dev/null 2>&1 || true
ok "App built."
printf "\n"

if [ "$CI" = "true" ]; then
    mkdir -p "$OLDPWD/Build"
    cp -R "$APP" "$OLDPWD/Build/"
    ok "CI mode detected. App copied to Build/$APP"
    exit 0
fi

# ---- Step 6: Install to /Applications -------------------------------------
step "Installing ClipLocal to /Applications…"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
DEST="/Applications/$APP_NAME.app"
INSTALLED=false

if [ "$FORCE_MODAL" = "1" ] || [ "$1" = "--modal" ] || [ "$1" = "--gui" ] || [ "$2" = "--modal" ]; then
    INSTALLED=false
elif [ -w "/Applications" ]; then
    rm -rf "$DEST" 2>/dev/null || true
    if cp -R "$APP" "$DEST" 2>/dev/null; then
        INSTALLED=true
    fi
fi

if [ "$INSTALLED" = "true" ]; then
    xattr -dr com.apple.quarantine "$DEST" >/dev/null 2>&1 || true
    ok "ClipLocal installed to /Applications."
    printf "\n"
    line
    printf "\n  ${GREEN}${BOLD}✓ ClipLocal is installed and running!${NC}\n\n"
    printf "  ${GREY}Look for the paperclip icon in your menu bar (top-right).${NC}\n\n"
    open "$DEST"
    exit 0
fi

# Fallback: Build drag-and-drop installer modal if permission required
warn "Standard install required elevated privileges. Opening installer modal…"
cat > Installer.swift <<'INSTEOF'
import Cocoa
import QuartzCore

let appName = "ClipLocal"
let sourcePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""

func getHighResIcon(path: String) -> NSImage {
    let icns = "\(path)/Contents/Resources/AppIcon.icns"
    if FileManager.default.fileExists(atPath: icns), let img = NSImage(contentsOfFile: icns) {
        img.size = NSSize(width: 128, height: 128)
        return img
    }
    let fallback = NSWorkspace.shared.icon(forFile: path)
    fallback.size = NSSize(width: 128, height: 128)
    return fallback
}

func performInstallation(src: URL) -> Bool {
    let dest = URL(fileURLWithPath: "/Applications").appendingPathComponent(src.lastPathComponent)
    do {
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: src, to: dest)
    } catch {
        let script = "do shell script \"rm -rf '/Applications/\(appName).app'; cp -R '\(src.path)' /Applications/\" with administrator privileges"
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
    clean.standardOutput = Pipe()
    clean.standardError = Pipe()
    try? clean.run(); clean.waitUntilExit()

    NSSound(named: "Glass")?.play()
    let a = NSAlert()
    a.messageText = "ClipLocal installed!"
    a.informativeText = "Look for the paperclip icon in your menu bar (top-right). It runs quietly with no Dock icon."
    a.addButton(withTitle: "Launch ClipLocal")
    a.addButton(withTitle: "Quit")
    if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(dest) }
    NSApp.terminate(nil)
    return true
}

class ActionTarget: NSObject {
    @objc static func oneClickInstall() {
        if !sourcePath.isEmpty {
            let src = URL(fileURLWithPath: sourcePath)
            _ = performInstallation(src: src)
        }
    }
}

// Icon you can drag with crisp 2x Retina rendering.
class DragIcon: NSImageView, NSDraggingSource {
    var fileURL: URL?
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
    override func mouseDown(with event: NSEvent) {
        guard let url = fileURL, let originalImg = image else { return }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        let drag = NSDraggingItem(pasteboardWriter: item)
        
        let dragImg = NSImage(size: bounds.size)
        dragImg.lockFocus()
        if let ctx = NSGraphicsContext.current {
            ctx.imageInterpolation = .high
        }
        originalImg.draw(in: bounds)
        dragImg.unlockFocus()
        
        drag.setDraggingFrame(bounds, contents: dragImg)
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
        return performInstallation(src: src)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let W: CGFloat = 620, H: CGFloat = 410
let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
win.title = "Install ClipLocal"
win.center()

let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: W, height: H))
bg.material = .windowBackground; bg.state = .active
win.contentView = bg

let title = NSTextField(labelWithString: "Install ClipLocal")
title.frame = NSRect(x: 0, y: H - 65, width: W, height: 30)
title.alignment = .center
title.font = NSFont.systemFont(ofSize: 22, weight: .bold)
bg.addSubview(title)

let sub = NSTextField(labelWithString: "Drag ClipLocal to Applications or click Instant Install below")
sub.frame = NSRect(x: 0, y: H - 90, width: W, height: 20)
sub.alignment = .center
sub.font = NSFont.systemFont(ofSize: 13)
sub.textColor = .secondaryLabelColor
bg.addSubview(sub)

let iconSize: CGFloat = 128
let midY: CGFloat = 145

// App icon (draggable)
let appIcon = DragIcon(frame: NSRect(x: 90, y: midY, width: iconSize, height: iconSize))
appIcon.imageScaling = .scaleProportionallyUpOrDown
appIcon.image = getHighResIcon(path: sourcePath)
appIcon.fileURL = URL(fileURLWithPath: sourcePath)
bg.addSubview(appIcon)

let appLabel = NSTextField(labelWithString: appName)
appLabel.frame = NSRect(x: 90, y: midY - 26, width: iconSize, height: 18)
appLabel.alignment = .center
appLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
bg.addSubview(appLabel)

// Gradient Arrow View (Fading Stem Arrow)
class GradientArrowView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let w = bounds.width
        let h = bounds.height
        let midY = h / 2.0
        
        let stemH: CGFloat = 10
        let headH: CGFloat = 26
        let headW: CGFloat = 20
        let stemR = w - headW
        
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: midY - stemH/2))
        path.line(to: NSPoint(x: stemR, y: midY - stemH/2))
        path.line(to: NSPoint(x: stemR, y: midY - headH/2))
        path.line(to: NSPoint(x: w, y: midY))
        path.line(to: NSPoint(x: stemR, y: midY + headH/2))
        path.line(to: NSPoint(x: stemR, y: midY + stemH/2))
        path.line(to: NSPoint(x: 0, y: midY + stemH/2))
        path.close()
        
        let startColor = NSColor.labelColor.withAlphaComponent(0.0)
        let endColor = NSColor.labelColor.withAlphaComponent(0.50)
        let gradient = NSGradient(starting: startColor, ending: endColor)
        gradient?.draw(in: path, angle: 0)
    }
}

let arrow = GradientArrowView(frame: NSRect(x: (W - 70)/2, y: midY + iconSize/2 - 18, width: 70, height: 36))
bg.addSubview(arrow)

// Applications folder (drop zone)
let drop = DropZone(frame: NSRect(x: W - 90 - iconSize, y: midY, width: iconSize, height: iconSize))
drop.imageScaling = .scaleProportionallyUpOrDown
let appsIcon = NSWorkspace.shared.icon(forFile: "/Applications")
appsIcon.size = NSSize(width: 128, height: 128)
drop.image = appsIcon
bg.addSubview(drop)

let appsLabel = NSTextField(labelWithString: "Applications")
appsLabel.frame = NSRect(x: W - 90 - iconSize, y: midY - 26, width: iconSize, height: 18)
appsLabel.alignment = .center
appsLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
bg.addSubview(appsLabel)

class AnimatedInstallButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { animateState() } }
    private var isPressed = false { didSet { animateState() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    private func setup() {
        wantsLayer = true
        isBordered = false
        focusRingType = .none
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0).cgColor
        contentTintColor = .white
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.pointingHand.set()
    }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSCursor.arrow.set()
    }
    override func mouseDown(with event: NSEvent) {
        isPressed = true
        super.mouseDown(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        isPressed = false
        super.mouseUp(with: event)
    }
    private func animateState() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            if isPressed {
                layer?.backgroundColor = NSColor(red: 0.14, green: 0.14, blue: 0.16, alpha: 1.0).cgColor
                layer?.transform = CATransform3DMakeScale(0.95, 0.95, 1.0)
            } else if isHovered {
                layer?.backgroundColor = NSColor(red: 0.28, green: 0.28, blue: 0.30, alpha: 1.0).cgColor
                layer?.transform = CATransform3DMakeScale(1.04, 1.04, 1.0)
                layer?.shadowColor = NSColor.black.cgColor
                layer?.shadowRadius = 8
                layer?.shadowOpacity = 0.35
                layer?.shadowOffset = .zero
            } else {
                layer?.backgroundColor = NSColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0).cgColor
                layer?.transform = CATransform3DIdentity
                layer?.shadowOpacity = 0
            }
        }
    }
}

// Instant 1-Click Install Button
let installBtn = AnimatedInstallButton(frame: NSRect(x: (W - 270)/2, y: 35, width: 270, height: 42))
installBtn.title = "⚡ One-Click Install to /Applications"
installBtn.font = NSFont.systemFont(ofSize: 13, weight: .bold)
installBtn.target = ActionTarget.self
installBtn.action = #selector(ActionTarget.oneClickInstall)
bg.addSubview(installBtn)

win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
INSTEOF

if xcrun swiftc -O ${SWIFT_SDK:+-sdk "$SWIFT_SDK"} -module-cache-path "$SWIFT_CACHE" -o Installer Installer.swift -framework Cocoa > /dev/null 2>&1; then
    ./Installer "$BUILD_DIR/$APP"
else
    osascript -e "do shell script \"rm -rf '$DEST'; cp -R '$BUILD_DIR/$APP' '/Applications/'\" with administrator privileges" >/dev/null 2>&1 || true
    xattr -dr com.apple.quarantine "$DEST" >/dev/null 2>&1 || true
    open "$DEST"
fi
printf "\n"
