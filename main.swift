import Cocoa
import CryptoKit
import ServiceManagement

// ============================================================
//  ClipLocal — 100% on-device clipboard history, no third parties
// ============================================================

let appVersion = "2.0"
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
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
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
    var imageData: Data?
}

enum PrivacyMode: String {
    case session
    case persistent
}

// MARK: - Custom Hover Table Row View
class HoverTableRowView: NSTableRowView {
    private var trackingArea: NSTrackingArea?
    var isHovered: Bool = false {
        didSet {
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInActiveWindow, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if isSelected {
            NSColor.selectedContentBackgroundColor.setFill()
            dirtyRect.fill()
        } else if isHovered {
            NSColor.quaternaryLabelColor.setFill()
            dirtyRect.fill()
        } else {
            super.drawBackground(in: dirtyRect)
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // We handle selection color drawing in drawBackground
    }
}

// MARK: - Custom Cell View for NSTableView
class ClipCellView: NSTableCellView {
    let iconImageView = NSImageView()
    let titleTextField = NSTextField()
    let shortcutTextField = NSTextField()
    let previewImageView = NSImageView()
    let metaTextField = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        iconImageView.imageScaling = .scaleProportionallyDown
        iconImageView.contentTintColor = .secondaryLabelColor
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconImageView)

        titleTextField.isEditable = false
        titleTextField.isSelectable = false
        titleTextField.isBordered = false
        titleTextField.drawsBackground = false
        titleTextField.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        titleTextField.lineBreakMode = .byTruncatingTail
        titleTextField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleTextField)

        shortcutTextField.isEditable = false
        shortcutTextField.isSelectable = false
        shortcutTextField.isBordered = false
        shortcutTextField.drawsBackground = false
        shortcutTextField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        shortcutTextField.textColor = .tertiaryLabelColor
        shortcutTextField.alignment = .right
        shortcutTextField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shortcutTextField)

        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(previewImageView)

        metaTextField.isEditable = false
        metaTextField.isSelectable = false
        metaTextField.isBordered = false
        metaTextField.drawsBackground = false
        metaTextField.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        metaTextField.textColor = .secondaryLabelColor
        metaTextField.lineBreakMode = .byTruncatingTail
        metaTextField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metaTextField)

        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 20),
            iconImageView.heightAnchor.constraint(equalToConstant: 20),

            shortcutTextField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shortcutTextField.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutTextField.widthAnchor.constraint(equalToConstant: 34),

            previewImageView.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 8),
            previewImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            previewImageView.widthAnchor.constraint(equalToConstant: 32),
            previewImageView.heightAnchor.constraint(equalToConstant: 32),

            titleTextField.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 8),
            titleTextField.trailingAnchor.constraint(equalTo: shortcutTextField.leadingAnchor, constant: -8),
            titleTextField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleTextField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

            metaTextField.leadingAnchor.constraint(equalTo: previewImageView.trailingAnchor, constant: 8),
            metaTextField.trailingAnchor.constraint(equalTo: shortcutTextField.leadingAnchor, constant: -8),
            metaTextField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(with item: ClipItem, index: Int, showDimensions: Bool) {
        let isImage = item.imageData != nil
        let shortcutText = index < 9 ? "⌘\(index + 1)" : ""
        shortcutTextField.stringValue = shortcutText

        iconImageView.image = NSImage(systemSymbolName: item.pinned ? "pin.fill" : iconName(for: item.text), accessibilityDescription: nil)

        if isImage, let data = item.imageData, let img = NSImage(data: data) {
            previewImageView.isHidden = false
            previewImageView.image = img
            titleTextField.isHidden = true
            metaTextField.isHidden = false

            if showDimensions {
                let width = Int(img.size.width)
                let height = Int(img.size.height)
                metaTextField.stringValue = "Image: \(width)x\(height)"
            } else {
                metaTextField.stringValue = "Image Preview"
            }
        } else {
            previewImageView.isHidden = true
            titleTextField.isHidden = false
            metaTextField.isHidden = true

            var displayText = item.text
            let isFile = item.text.hasPrefix("file://") || item.text.hasPrefix("/")
            if isFile {
                let path = item.text.hasPrefix("file://") ? String(item.text.dropFirst(7)) : item.text
                let url = URL(fileURLWithPath: path)
                displayText = url.lastPathComponent
            }

            let cleanText = displayText
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            titleTextField.stringValue = cleanText
        }
    }

    private func iconName(for text: String) -> String {
        if text.hasPrefix("[Image:") { return "photo" }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        let isCode = t.contains("{") || t.contains("}") || t.contains("<") || t.contains(">") || t.hasPrefix("func ") || t.hasPrefix("import ") || t.hasPrefix("class ")
        if isCode { return "chevron.left.forwardslash.chevron.right" }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") { return "link" }
        if t.contains("@"), t.contains("."), !t.contains(" "), t.count < 60 { return "envelope" }
        if t.range(of: "^[0-9 +().-]{5,}$", options: .regularExpression) != nil { return "number" }
        if lower.hasPrefix("file://") || lower.hasPrefix("/") { return "doc" }
        return "text.alignleft"
    }
}

// MARK: - Filter Button (Smooth hover/active toggles)
class PopoverFilterButton: NSButton {
    var filterName: String = ""
    var hasItems: Bool = false {
        didSet { updateVisuals(animated: false) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        setButtonType(.toggle)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 5
        imageScaling = .scaleProportionallyDown
        refusesFirstResponder = true
    }

    func setSelected(_ selected: Bool, animated: Bool = true) {
        self.state = selected ? .on : .off
        updateVisuals(animated: animated)
    }

    private func updateVisuals(animated: Bool) {
        let selected = self.state == .on
        let updateUI = {
            if selected {
                self.contentTintColor = .white
                self.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                self.alphaValue = 1.0
            } else {
                self.layer?.backgroundColor = NSColor.clear.cgColor
                if self.hasItems {
                    self.contentTintColor = .labelColor
                    self.alphaValue = 1.0
                } else {
                    self.contentTintColor = .tertiaryLabelColor
                    self.alphaValue = 0.3
                }
            }
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.allowsImplicitAnimation = true
                updateUI()
            }
        } else {
            updateUI()
        }
    }
}

// MARK: - Popover Content View Controller
class PopoverViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    weak var appDelegate: AppDelegate?

    let searchField = NSSearchField()
    let filtersStackView = NSStackView()
    let scrollView = NSScrollView()
    let tableView = NSTableView()
    let bottomBar = NSView()
    let settingsButton = NSButton()
    let clearButton = NSButton()

    var filteredItems: [(originalIndex: Int, item: ClipItem)] = []
    var activeFilters: Set<String> = []
    var currentSearchText = ""

    override func loadView() {
        let mainView = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 460))
        mainView.wantsLayer = true
        self.view = mainView

        setupSearchField()
        setupFilters()
        setupScrollView()
        setupBottomBar()

        setupLayoutConstraints()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(tableViewDoubleClicked(_:))
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshData()
        self.view.window?.makeFirstResponder(searchField)
    }

    func refreshData() {
        guard let appDelegate = appDelegate else { return }

        let originalHistory = appDelegate.history
        var categoryCounts: [String: Int] = [
            "link": 0, "image": 0, "text": 0, "file": 0, "number": 0, "email": 0, "code": 0
        ]

        for item in originalHistory {
            let t = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let textLower = t.lowercased()
            let isImage = item.imageData != nil
            let isCode = t.contains("{") || t.contains("}") || t.contains("<") || t.contains(">") || t.hasPrefix("func ") || t.hasPrefix("import ") || t.hasPrefix("class ")
            let isLink = textLower.hasPrefix("http://") || textLower.hasPrefix("https://") || textLower.hasPrefix("www.")
            let isEmail = t.contains("@") && t.contains(".") && !t.contains(" ") && t.count < 60
            let isNum = t.range(of: "^[0-9 +().-]{5,}$", options: .regularExpression) != nil
            let isFile = textLower.hasPrefix("file://") || textLower.hasPrefix("/")
            let isText = !isImage && !isLink && !isEmail && !isNum && !isCode && !isFile

            if isLink { categoryCounts["link"]! += 1 }
            if isImage { categoryCounts["image"]! += 1 }
            if isText { categoryCounts["text"]! += 1 }
            if isFile { categoryCounts["file"]! += 1 }
            if isCode { categoryCounts["code"]! += 1 }
            if isNum { categoryCounts["number"]! += 1 }
            if isEmail { categoryCounts["email"]! += 1 }
        }

        for view in filtersStackView.views {
            if let btn = view as? PopoverFilterButton {
                let count = categoryCounts[btn.filterName] ?? 0
                btn.hasItems = count > 0
            }
        }

        filteredItems = []
        for (i, item) in originalHistory.enumerated() {
            var matchesSearch = true
            if !currentSearchText.isEmpty {
                matchesSearch = item.text.lowercased().contains(currentSearchText)
            }

            var matchesFilter = true
            if !activeFilters.isEmpty {
                var filterMatched = false
                let t = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let textLower = t.lowercased()
                let isImage = item.imageData != nil
                let isCode = t.contains("{") || t.contains("}") || t.contains("<") || t.contains(">") || t.hasPrefix("func ") || t.hasPrefix("import ") || t.hasPrefix("class ")
                let isLink = textLower.hasPrefix("http://") || textLower.hasPrefix("https://") || textLower.hasPrefix("www.")
                let isEmail = t.contains("@") && t.contains(".") && !t.contains(" ") && t.count < 60
                let isNum = t.range(of: "^[0-9 +().-]{5,}$", options: .regularExpression) != nil
                let isFile = textLower.hasPrefix("file://") || textLower.hasPrefix("/")
                let isText = !isImage && !isLink && !isEmail && !isNum && !isCode && !isFile

                if activeFilters.contains("link") && isLink { filterMatched = true }
                if activeFilters.contains("email") && isEmail { filterMatched = true }
                if activeFilters.contains("number") && isNum { filterMatched = true }
                if activeFilters.contains("image") && isImage { filterMatched = true }
                if activeFilters.contains("file") && isFile { filterMatched = true }
                if activeFilters.contains("code") && isCode { filterMatched = true }
                if activeFilters.contains("text") && isText { filterMatched = true }

                matchesFilter = filterMatched
            }

            if matchesSearch && matchesFilter {
                filteredItems.append((originalIndex: i, item: item))
            }
        }

        tableView.reloadData()
    }

    private func setupSearchField() {
        searchField.placeholderString = "Search history..."
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(searchField)
    }

    private func setupFilters() {
        filtersStackView.orientation = .horizontal
        filtersStackView.distribution = .equalSpacing
        filtersStackView.alignment = .centerY
        filtersStackView.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(filtersStackView)

        let filters = [
            ("code", "chevron.left.forwardslash.chevron.right"),
            ("email", "envelope"),
            ("file", "doc"),
            ("image", "photo"),
            ("link", "link"),
            ("number", "number"),
            ("text", "text.alignleft")
        ]

        for filter in filters {
            let btn = PopoverFilterButton(frame: .zero)
            btn.image = NSImage(systemSymbolName: filter.1, accessibilityDescription: nil)
            btn.target = self
            btn.action = #selector(filterToggled(_:))
            btn.filterName = filter.0
            btn.toolTip = "Filter by \(filter.0)"

            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(equalToConstant: 26).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 22).isActive = true
            filtersStackView.addView(btn, in: .leading)
        }
    }

    private func setupScrollView() {
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(scrollView)

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clipColumn"))
        col.width = 310
        tableView.addTableColumn(col)

        scrollView.documentView = tableView
    }

    private func setupBottomBar() {
        bottomBar.wantsLayer = true
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(bottomBar)

        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        settingsButton.isBordered = false
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked(_:))
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(settingsButton)

        clearButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear history")
        clearButton.isBordered = false
        clearButton.target = self
        clearButton.action = #selector(clearClicked(_:))
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(clearButton)
    }

    private func setupLayoutConstraints() {
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: self.view.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -14),
            searchField.heightAnchor.constraint(equalToConstant: 24),

            filtersStackView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            filtersStackView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 14),
            filtersStackView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -14),
            filtersStackView.heightAnchor.constraint(equalToConstant: 24),

            scrollView.topAnchor.constraint(equalTo: filtersStackView.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 38),

            clearButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 14),
            clearButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 24),
            clearButton.heightAnchor.constraint(equalToConstant: 24),

            settingsButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -14),
            settingsButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            settingsButton.widthAnchor.constraint(equalToConstant: 24),
            settingsButton.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    // MARK: - Table view dataSource & delegate
    func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ClipCell")
        var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ClipCellView
        if cell == nil {
            cell = ClipCellView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: 44))
            cell?.identifier = identifier
        }

        let entry = filteredItems[row]
        let showDimensions = appDelegate?.showImageDimensions ?? false
        cell?.configure(with: entry.item, index: row, showDimensions: showDimensions)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("HoverRow")
        var rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? HoverTableRowView
        if rowView == nil {
            rowView = HoverTableRowView()
            rowView?.identifier = identifier
        }
        return rowView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 44
    }

    // MARK: - Native Swipe Actions
    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        let entry = filteredItems[row]

        if edge == .trailing {
            // Delete action
            let deleteAction = NSTableViewRowAction(style: .destructive, title: "Delete") { [weak self] (_, _) in
                guard let self = self, let appDelegate = self.appDelegate else { return }
                let originalIndex = entry.originalIndex
                appDelegate.history.remove(at: originalIndex)
                appDelegate.persistIfNeeded()
                self.refreshData()
            }
            deleteAction.backgroundColor = .systemRed
            return [deleteAction]
        } else if edge == .leading {
            // Pin / Unpin action
            let isPinned = entry.item.pinned
            let pinTitle = isPinned ? "Unpin" : "Pin"
            let pinAction = NSTableViewRowAction(style: .regular, title: pinTitle) { [weak self] (_, _) in
                guard let self = self, let appDelegate = self.appDelegate else { return }
                let originalIndex = entry.originalIndex
                appDelegate.history[originalIndex].pinned.toggle()
                appDelegate.persistIfNeeded()
                self.refreshData()
            }
            pinAction.backgroundColor = isPinned ? .systemBlue : .systemOrange
            return [pinAction]
        }

        return []
    }

    // MARK: - Actions
    @objc func filterToggled(_ sender: PopoverFilterButton) {
        let isActivating = sender.state == .on
        sender.setSelected(isActivating, animated: true)

        if isActivating {
            activeFilters.insert(sender.filterName)
        } else {
            activeFilters.remove(sender.filterName)
        }
        refreshData()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        currentSearchText = field.stringValue.lowercased()
        refreshData()
    }

    @objc func tableViewDoubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0 && row < filteredItems.count else { return }
        copyItemAndDismiss(atRow: row)
    }

    func copyItemAndDismiss(atRow row: Int) {
        guard let appDelegate = appDelegate else { return }
        let entry = filteredItems[row]
        appDelegate.copyItemWithIndex(entry.originalIndex)
        appDelegate.closePopover()
    }

    @objc func clearClicked(_ sender: NSButton) {
        guard let appDelegate = appDelegate else { return }
        appDelegate.clearNow()
        refreshData()
    }

    @objc func settingsClicked(_ sender: NSButton) {
        guard let appDelegate = appDelegate else { return }
        let menu = appDelegate.buildSettingsMenu()
        let p = NSPoint(x: 0, y: sender.bounds.height)
        menu.popUp(positioning: nil, at: p, in: sender)
    }

    // MARK: - Keyboard Handling
    override func keyUp(with event: NSEvent) {
        // Return key on selected table view row
        if event.keyCode == 36 { // Enter / Return
            let row = tableView.selectedRow
            if row >= 0 && row < filteredItems.count {
                copyItemAndDismiss(atRow: row)
                return
            }
        }

        // Command + number logic
        if event.modifierFlags.contains(.command) {
            if let chars = event.charactersIgnoringModifiers, chars.count == 1 {
                if let num = Int(chars), num >= 1 && num <= 9 {
                    let index = num - 1
                    if index < filteredItems.count {
                        copyItemAndDismiss(atRow: index)
                        return
                    }
                }
            }
        }
        super.keyUp(with: event)
    }
}

// MARK: - Custom Popover to ensure Key status
class ClipboardPopover: NSPopover {
    override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

// MARK: - The app Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var lastChangeCount = NSPasteboard.general.changeCount
    var history: [ClipItem] = []
    let key = KeyStore.loadOrCreateKey()
    let defaults = UserDefaults.standard
    var previewWindow: NSWindow?

    let popover = ClipboardPopover()
    var popoverViewController: PopoverViewController!

    var mode: PrivacyMode {
        get { PrivacyMode(rawValue: defaults.string(forKey: "mode") ?? "persistent") ?? .persistent }
        set { defaults.set(newValue.rawValue, forKey: "mode"); persistIfNeeded(); popoverViewController?.refreshData() }
    }
    var skipConcealed: Bool {
        get { defaults.object(forKey: "skipConcealed") == nil ? true : defaults.bool(forKey: "skipConcealed") }
        set { defaults.set(newValue, forKey: "skipConcealed"); popoverViewController?.refreshData() }
    }
    var showImageDimensions: Bool {
        get { defaults.bool(forKey: "showImageDimensions") }
        set { defaults.set(newValue, forKey: "showImageDimensions"); popoverViewController?.refreshData() }
    }
    var maxItems: Int {
        get { let v = defaults.integer(forKey: "maxItems"); return v == 0 ? 50 : v }
        set { defaults.set(newValue, forKey: "maxItems"); popoverViewController?.refreshData() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if defaults.object(forKey: "hasLaunchedBefore") == nil {
            defaults.set(true, forKey: "hasLaunchedBefore")
            try? SMAppService.mainApp.register()
        }

        NSApp.setActivationPolicy(.accessory) // menu-bar only, no dock icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard",
                                   accessibilityDescription: "ClipLocal")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
        }

        popoverViewController = PopoverViewController()
        popoverViewController.appDelegate = self
        popover.contentViewController = popoverViewController
        popover.behavior = .transient

        if mode == .persistent { loadHistory() }
        showAbout(onLaunch: true)
        checkForUpdates(silentIfCurrent: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    @objc func statusItemClicked(_ sender: AnyObject?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        if let button = statusItem.button {
            // Activating application is necessary for key window/popover focus
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() {
        popover.performClose(nil)
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

        let icon = NSImageView(frame: NSRect(x: (width - 72)/2, y: height - 120, width: 72, height: 72))
        let cfg = NSImage.SymbolConfiguration(pointSize: 60, weight: .regular)
        icon.image = NSImage(systemSymbolName: "lock.doc.fill", accessibilityDescription: nil)?
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

        let bodyText = """
        🔒  100% on-device. Your clipboard data NEVER leaves your Mac — no cloud, no servers, no accounts, no analytics, no third parties. Ever.

        💾  In Persistent mode, history is encrypted with a key stored in a protected file that only your macOS account can read.

        🔑  Session-only mode keeps everything in memory and wipes it the moment you quit.

        🛡️  Copies from password managers are skipped by default, and you can clear everything instantly anytime.

        ⌘  Open the popover and press ⌘1–⌘9 to instantly copy any of your recent items.

        🏷️  Each item shows a relevant icon — 🔗 links, ✉️ emails, #️⃣ numbers, 🧑‍💻 code, 📄 files, and 🖼️ images — so your history is easy to scan.

        👉  Swipe LEFT on a row to delete it, or swipe RIGHT to pin / unpin it!
        """
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 3
        let attr = NSAttributedString(string: bodyText, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ])
        let bodyWidth = width - 80
        let measured = attr.boundingRect(
            with: NSSize(width: bodyWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let textHeight = ceil(measured.height) + 8
        let privacy = NSTextField(labelWithAttributedString: attr)
        privacy.lineBreakMode = .byWordWrapping
        privacy.maximumNumberOfLines = 0
        privacy.preferredMaxLayoutWidth = bodyWidth
        let textTop = (height - 210) - 24

        let bottomSpaceNeeded: CGFloat = 160
        let newHeight = (height - textTop) + textHeight + bottomSpaceNeeded
        let finalHeight = max(height, newHeight)

        let oldFrame = win.frame
        win.setFrame(NSRect(x: oldFrame.minX, y: oldFrame.maxY - finalHeight, width: width, height: finalHeight), display: true)
        bg.frame = NSRect(x: 0, y: 0, width: width, height: finalHeight)

        icon.frame.origin.y = finalHeight - 120
        name.frame.origin.y = finalHeight - 164
        version.frame.origin.y = finalHeight - 186
        tagline.frame.origin.y = finalHeight - 210
        let newTextTop = (finalHeight - 210) - 24

        privacy.frame = NSRect(x: 40, y: newTextTop - textHeight, width: bodyWidth, height: textHeight)
        bg.addSubview(privacy)

        let credit = NSTextField(labelWithString: "Built by Arun Thomas")
        credit.frame = NSRect(x: 0, y: (newTextTop - textHeight) - 34, width: width, height: 18)
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
        dontShow.state = defaults.bool(forKey: "hideAbout") ? .on : .off
        bg.addSubview(dontShow)

        let contact = NSButton(title: "Contact", target: self, action: #selector(contactDeveloper))
        let buttonsY = dontShow.frame.minY - 48
        contact.frame = NSRect(x: 40, y: buttonsY, width: 100, height: 32)
        contact.bezelStyle = .rounded
        bg.addSubview(contact)

        let close = NSButton(title: "Get Started", target: self, action: #selector(closeAbout))
        close.frame = NSRect(x: width - 160, y: buttonsY, width: 120, height: 32)
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

        var textToStore = ""
        var imageToStore: Data? = nil

        if let fileURLs = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let firstURL = fileURLs.first, firstURL.isFileURL {
            textToStore = firstURL.path
        } else if let img = NSImage(pasteboard: pb),
           let tiff = img.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            imageToStore = pngData
            textToStore = "[Image: \(Int(img.size.width))x\(Int(img.size.height))]"
        } else if let text = pb.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textToStore = text
        } else {
            return
        }

        var pinned = false
        if let idx = history.firstIndex(where: {
            if let img1 = $0.imageData, let img2 = imageToStore {
                return img1 == img2
            }
            return $0.imageData == nil && imageToStore == nil && $0.text == textToStore
        }) {
            pinned = history[idx].pinned
            history.remove(at: idx)
        }
        history.insert(ClipItem(text: textToStore, date: Date(), pinned: pinned, imageData: imageToStore), at: 0)
        trimHistory()
        persistIfNeeded()
        popoverViewController?.refreshData()
        showPreview(textToStore)
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

    // MARK: - Menu Settings Builder
    func buildSettingsMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "ClipLocal Settings", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Storage mode submenu
        let privacy = NSMenuItem(title: "History Storage", action: nil, keyEquivalent: "")
        privacy.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        let psub = NSMenu()
        let sessionItem = NSMenuItem(title: "Session-only (wiped on quit)",
                                     action: #selector(setSession), keyEquivalent: "")
        sessionItem.image = NSImage(systemSymbolName: "lock", accessibilityDescription: nil)
        sessionItem.target = self
        sessionItem.state = mode == .session ? .on : .off
        let persistItem = NSMenuItem(title: "Persistent (kept on quit)",
                                     action: #selector(setPersistent), keyEquivalent: "")
        persistItem.image = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: nil)
        persistItem.target = self
        persistItem.state = mode == .persistent ? .on : .off
        psub.addItem(sessionItem); psub.addItem(persistItem)
        privacy.submenu = psub
        menu.addItem(privacy)

        // Limits submenu
        let sizeItem = NSMenuItem(title: "Keep up to…", action: nil, keyEquivalent: "")
        sizeItem.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        let sizeSub = NSMenu()
        for n in [10, 25, 50, 100, 200] {
            let opt = NSMenuItem(title: "\(n) items", action: #selector(setHistorySize(_:)), keyEquivalent: "")
            opt.target = self
            opt.tag = n
            opt.state = maxItems == n ? .on : .off
            sizeSub.addItem(opt)
        }
        sizeItem.submenu = sizeSub
        menu.addItem(sizeItem)

        menu.addItem(.separator())

        let skip = NSMenuItem(title: "Skip password-manager copies",
                              action: #selector(toggleSkip), keyEquivalent: "")
        skip.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
        skip.target = self
        skip.state = skipConcealed ? .on : .off
        menu.addItem(skip)

        let showDims = NSMenuItem(title: "Show image dimensions",
                                  action: #selector(toggleShowImageDimensions), keyEquivalent: "")
        showDims.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)
        showDims.target = self
        showDims.state = showImageDimensions ? .on : .off
        menu.addItem(showDims)

        let launch = NSMenuItem(title: "Launch at Login",
                                action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        launch.target = self
        launch.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())

        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesMenu), keyEquivalent: "")
        updates.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        updates.target = self
        menu.addItem(updates)

        let about = NSMenuItem(title: "About ClipLocal", action: #selector(showAboutMenu), keyEquivalent: "")
        about.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit ClipLocal", action: #selector(quitApp), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: - Action implementation
    func copyItemWithIndex(_ i: Int) {
        guard i < history.count else { return }
        let item = history[i]
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

        lastChangeCount = pb.changeCount
        let pinned = item.pinned
        history.remove(at: i)
        history.insert(ClipItem(text: item.text, date: Date(), pinned: pinned, imageData: item.imageData), at: 0)
        persistIfNeeded()
        popoverViewController?.refreshData()
    }

    @objc func setSession() { mode = .session; deleteStore() }
    @objc func setPersistent() { mode = .persistent; saveHistory() }
    @objc func toggleSkip() { skipConcealed.toggle() }
    @objc func toggleShowImageDimensions() { showImageDimensions.toggle() }

    @objc func setHistorySize(_ sender: NSMenuItem) {
        maxItems = sender.tag
        trimHistory()
        persistIfNeeded()
        popoverViewController?.refreshData()
    }

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
        popoverViewController?.refreshData()
    }

    @objc func clearNow() {
        history = history.filter { $0.pinned }
        if history.isEmpty {
            deleteStore()
        } else {
            persistIfNeeded()
        }
        popoverViewController?.refreshData()
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    // MARK: - Update check
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
