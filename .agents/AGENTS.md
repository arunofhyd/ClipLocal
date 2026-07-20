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

## 3. Workflow
- **Compile & Verify**: Before presenting a completed feature, compile the app locally using `swiftc`, kill the existing process (`pkill`), and launch the newly compiled `.app` so it can be tested locally.
- **Wait for Approval**: Avoid unprompted Git pushes. Wait for the user to test the local build and give the green light before pushing to GitHub.
