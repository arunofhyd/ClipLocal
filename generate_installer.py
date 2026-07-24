import os
import sys
import base64

script_dir = os.path.dirname(os.path.abspath(__file__))
main_swift_path = os.path.join(script_dir, "main.swift")
logo_png_path = os.path.join(script_dir, "logo-cliplocal.png")

if not os.path.exists(main_swift_path):
    main_swift_path = "main.swift"

if not os.path.exists(logo_png_path):
    logo_png_path = "logo-cliplocal.png"

with open(main_swift_path, "r", encoding="utf-8") as f:
    swift_code = f.read()

swift_b64 = base64.b64encode(swift_code.encode("utf-8")).decode("utf-8")

if os.path.exists(logo_png_path):
    with open(logo_png_path, "rb") as f:
        logo_png_b64 = base64.b64encode(f.read()).decode("utf-8")
else:
    logo_png_b64 = ""

command_content = f"""#!/usr/bin/env python3
import os
import sys
import subprocess
import base64
import shutil
from pathlib import Path

VERSION = "v1.1.9"
CONTACT_EMAIL = "arunthomashyd@gmail.com"
APP_NAME = "ClipLocal"
PLIST_LABEL = "com.aoh.cliplocal"

SWIFT_B64 = \"\"\"{swift_b64}\"\"\"
LOGO_PNG_B64 = \"\"\"{logo_png_b64}\"\"\"

IS_CI = os.environ.get("CI") == "true" or "--ci" in sys.argv

def build_app_ci():
    script_dir = Path(os.path.dirname(os.path.abspath(__file__)))
    build_dir = script_dir / "Build"
    target_app = build_dir / f"{{APP_NAME}}.app"
    
    if build_dir.exists():
        shutil.rmtree(build_dir)
    build_dir.mkdir(parents=True, exist_ok=True)
    
    main_swift = build_dir / "main.swift"
    with open(main_swift, "w", encoding="utf-8") as f:
        f.write(base64.b64decode(SWIFT_B64).decode("utf-8"))
        
    exec_path = build_dir / APP_NAME
    res = subprocess.run([
        "swiftc", "-O", str(main_swift),
        "-o", str(exec_path),
        "-framework", "AppKit",
        "-framework", "SwiftUI",
        "-framework", "ServiceManagement"
    ], capture_output=True, text=True)
    
    if res.returncode != 0:
        print(f"Compilation failed: {{res.stderr}}")
        sys.exit(1)
        
    contents_dir = target_app / "Contents"
    macos_dir = contents_dir / "MacOS"
    resources_dir = contents_dir / "Resources"
    
    macos_dir.mkdir(parents=True, exist_ok=True)
    resources_dir.mkdir(parents=True, exist_ok=True)
    
    shutil.copy2(exec_path, macos_dir / APP_NAME)
    os.chmod(macos_dir / APP_NAME, 0o755)
    
    png_source = build_dir / "logo-cliplocal.png"
    if LOGO_PNG_B64:
        with open(png_source, "wb") as f:
            f.write(base64.b64decode(LOGO_PNG_B64))
            
    if png_source.exists():
        iconset = build_dir / "AppIcon.iconset"
        iconset.mkdir(exist_ok=True)
        sizes = [
            (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
        ]
        for sz, filename in sizes:
            subprocess.run(["sips", "-z", str(sz), str(sz), str(png_source), "--out", str(iconset / filename)], capture_output=True)
            
        icns_out = resources_dir / "AppIcon.icns"
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns_out)], capture_output=True)
        shutil.copy2(png_source, resources_dir / "AppIcon.png")
        
    info_plist = contents_dir / "Info.plist"
    info_plist_content = f\"\"\"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>{{APP_NAME}}</string>
    <key>CFBundleIdentifier</key>
    <string>{{PLIST_LABEL}}</string>
    <key>CFBundleName</key>
    <string>ClipLocal</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.9</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>\"\"\"
    with open(info_plist, "w", encoding="utf-8") as f:
        f.write(info_plist_content)
        
    print(f"CI Build Complete: {{target_app}}")

def main_interactive():
    C_APP = "\\033[1;36m"
    C_OK  = "\\033[1;32m"
    C_ERR = "\\033[1;31m"
    C_INF = "\\033[1;34m"
    C_DIM = "\\033[2m"
    C_RST = "\\033[0m"

    print("\\033[2J\\033[H", end="")
    print(f"\\n    {{C_APP}}📋  ClipLocal{{C_RST}}  {{C_DIM}}{{VERSION}}{{C_RST}}")
    print(f"    {{C_DIM}}Built by Arun Thomas ({{CONTACT_EMAIL}}){{C_RST}}\\n")
    print(f"    {{C_DIM}}Private Clipboard History for macOS.{{C_RST}}")
    print(f"   {{C_DIM}}──────────────────────────────────────────────────────────{{C_RST}}\\n")

    print(f"    {{C_INF}}●{{C_RST}} {{C_APP}}Select an option:{{C_RST}}\\n")
    print(f"       1)  Install / Compile ClipLocal (Complete Setup)")
    print(f"       2)  Uninstall ClipLocal")
    
    choice = input(f"\\n    {{C_APP}}►  Enter choice (1 or 2) [1]: {{C_RST}}").strip()
    print()
    
    if choice == "2":
        print(f"    {{C_INF}}●{{C_RST}} Uninstalling ClipLocal...")
        home = Path.home()
        target_app = home / "Applications/ClipLocal.app"
        plist_path = home / f"Library/LaunchAgents/{{PLIST_LABEL}}.plist"
        subprocess.run(["pkill", "-f", "ClipLocal"], capture_output=True)
        if plist_path.exists():
            subprocess.run(["launchctl", "unload", str(plist_path)], capture_output=True)
            try: os.remove(plist_path)
            except OSError: pass
        if target_app.exists():
            shutil.rmtree(target_app, ignore_errors=True)
        print(f"    {{C_OK}}✔{{C_RST}} Uninstalled successfully.")
    else:
        build_app_ci()
        home = Path.home()
        target_app = home / "Applications/ClipLocal.app"
        build_app = Path(os.path.dirname(os.path.abspath(__file__))) / "Build/ClipLocal.app"
        
        subprocess.run(["pkill", "-f", "ClipLocal"], capture_output=True)
        if target_app.exists():
            shutil.rmtree(target_app, ignore_errors=True)
            
        shutil.copytree(build_app, target_app)
        os.chmod(target_app / "Contents/MacOS/ClipLocal", 0o755)
        
        launch_agent_dir = home / "Library/LaunchAgents"
        launch_agent_dir.mkdir(parents=True, exist_ok=True)
        plist_path = launch_agent_dir / f"{{PLIST_LABEL}}.plist"
        plist_content = f\"\"\"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{{PLIST_LABEL}}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{{target_app}}/Contents/MacOS/ClipLocal</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>\"\"\"
        with open(plist_path, "w", encoding="utf-8") as f:
            f.write(plist_content)
            
        subprocess.run(["launchctl", "unload", str(plist_path)], capture_output=True)
        subprocess.run(["launchctl", "load", str(plist_path)], capture_output=True)
        subprocess.run(["touch", str(target_app)], capture_output=True)
        subprocess.run(["open", str(target_app)], capture_output=True)
        print(f"    {{C_OK}}✔{{C_RST}} Installation Complete!")

if __name__ == "__main__":
    if IS_CI:
        build_app_ci()
    else:
        main_interactive()
"""

out_command = os.path.join(script_dir, "install-cliplocal.command")
with open(out_command, "w", encoding="utf-8") as f:
    f.write(command_content)

os.chmod(out_command, 0o755)
print("Generated install-cliplocal.command with generate_installer.py successfully!")
