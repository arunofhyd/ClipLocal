# ClipLocal Agent Rules & Best Practices

These rules help guide AI behavior when working inside the ClipLocal repository to maintain high code quality and performance.

## 1. Performance & Architecture
- **O(1) Over O(N)**: Avoid O(N) array calculations inside UI render loops. Default to centralized dictionaries/caches updated in the background.
- **Smart Memory Management**: Clean up temporary data gracefully. Use `NSCache` for dynamic items (like image previews) and garbage-collect dead Handoff links to keep the UI snappy.
- **Native Ecosystem Focus**: Prefer native macOS APIs (AppKit, Swift, ScreenCaptureKit, CryptoKit). If a third-party dependency is required for a major feature, propose it for discussion first.
- **Privacy by Design**: Treat clipboard data securely. Skip concealed items (e.g., password managers) by default.

## 2. Code Quality & UX
- **Clean Code**: Use `// MARK: -` comments to keep `main.swift` organized and readable.
- **Subtle User Feedback**: When performing background actions (like copying or clearing history), ensure there are subtle visual or haptic cues so the user knows it succeeded.

## 3. Release & Git Workflow
- **Local Rebuild & Replace**: Always rebuild the app locally using `swiftc`, replace `/Applications/ClipLocal.app/Contents/MacOS/ClipLocal`, re-sign with `codesign`, and launch it so the user can test locally.
- **NEVER Auto-Push**: NEVER execute `git push` automatically without explicit user instructions. Always wait for the user to test the local build.
- **Version Prompting**: When the user explicitly requests to push to GitHub, ask/confirm whether the release is a **Major**, **Minor**, or **Patch** bump before updating `version.json` and pushing.
