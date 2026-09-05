import AppKit
import BaiaSettings

/// The Settings window: a toolbar of categories over a scrolling page of
/// controls, every control writing the file as it validates.
///
/// One window for the life of the process. `AppDelegate.showSettings(_:)`
/// brings it forward; it never closes to be rebuilt, so the category stays
/// selected and a text field mid-edit keeps its text across a second ⌘,
/// (audit S1). There is no Apply, Cancel or Accept: nothing is staged, so
/// closing needs no prompt.
///
/// Every write goes through ``SettingsTransactionController``, owned here so
/// its undo entries land on this window's own `UndoManager`. The standard
/// Edit menu reaches that manager through the responder chain while this
/// window is key (``windowWillReturnUndoManager(_:)``), and a workspace window
/// that becomes key gets its own manager back, so Undo never crosses windows.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let center: ConfigurationCenter
    private let acknowledgement: CommandExecutionAcknowledgement
    let transactions: SettingsTransactionController
    let settingsUndoManager = UndoManager()
    private let toolbar = NSToolbar(identifier: "pasqualotto.baia.settings")
    private let scrollView = NSScrollView()
    let banner = SettingsRecoveryBanner()
    let preview = SettingsPreviewController()
    private(set) var pages: [SettingsCategory: SettingsPageController] = [:]
    private(set) var selected: SettingsCategory = .appearance
    private var hasBeenShown = false

    init(center: ConfigurationCenter, acknowledgement: CommandExecutionAcknowledgement) {
        self.center = center
        self.acknowledgement = acknowledgement
        transactions = SettingsTransactionController(
            store: center.store,
            settings: center.settings,
            undoManager: settingsUndoManager
        ) { [center] settings in center.adopt(settings) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = SettingsCategory.appearance.title
        window.toolbarStyle = .preference
        window.minSize = NSSize(width: 640, height: 420)
        window.setFrameAutosaveName("Settings")
        super.init(window: window)
        window.delegate = self

        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = Self.identifier(for: selected)
        window.toolbar = toolbar

        banner.onReveal = { [weak self] in self?.revealFile() }
        banner.onRepair = { [weak self] in self?.repair() }
        banner.isHidden = true

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let content = NSStackView(views: [banner, scrollView])
        content.orientation = .vertical
        content.spacing = 0
        content.alignment = .leading
        content.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            banner.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        window.contentView = container

        center.onSettingsChange { [weak self] in self?.settingsDidChange() }
        select(selected)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    /// Brings the window forward, centred the first time and where it was left
    /// after that.
    func show() {
        if !hasBeenShown {
            hasBeenShown = true
            window?.center()
        }
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Categories

    private static func identifier(for category: SettingsCategory) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(category.rawValue)
    }

    func page(for category: SettingsCategory) -> SettingsPageController {
        if let page = pages[category] { return page }
        let page = SettingsPages.make(
            category,
            editor: self,
            center: center,
            acknowledgement: acknowledgement,
            preview: category == .appearance ? preview : nil,
            confirmCommandExecution: { [weak self] in self?.confirmCommandExecution() ?? false }
        )
        pages[category] = page
        return page
    }

    func select(_ category: SettingsCategory) {
        selected = category
        let page = page(for: category)
        page.refresh(transactions.settings)
        let document = page.view
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        window?.title = category.title
        toolbar.selectedItemIdentifier = Self.identifier(for: category)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
    }

    @objc private func selectCategory(_ sender: NSToolbarItem) {
        guard let category = SettingsCategory(rawValue: sender.itemIdentifier.rawValue) else { return }
        select(category)
    }

    // MARK: - Refreshing

    /// Every page that exists takes the running value; the recovery state is
    /// re-inspected. Called on every settings change, including the ones this
    /// window's own transactions produce.
    private func refresh() {
        for page in pages.values {
            page.refresh(transactions.settings)
        }
        refreshRecoveryState()
    }

    private func settingsDidChange() {
        transactions.noteExternalReload(center.settings)
        refresh()
    }

    func refreshRecoveryState() {
        banner.present(
            state: transactions.documentState(),
            failure: transactions.lastFailure,
            fileURL: transactions.fileURL
        )
    }

    // MARK: - Recovery

    private func revealFile() {
        NSWorkspace.shared.activateFileViewerSelecting([transactions.fileURL])
    }

    private func repair() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Repair the configuration file?"
        alert.informativeText = "Baia will keep the current file as a backup beside it, then write a new configuration from the settings in effect now. Nothing in the original is lost."
        alert.addButton(withTitle: "Repair")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            switch transactions.repair() {
            case let .success(backup):
                refresh()
                let done = NSAlert()
                done.messageText = "Configuration repaired"
                done.informativeText = "The original file is kept at \(backup.path(percentEncoded: false))."
                done.beginSheetModal(for: window)
            case let .failure(failure):
                refreshRecoveryState()
                let failed = NSAlert()
                failed.messageText = "The configuration could not be repaired"
                failed.informativeText = failure.message
                failed.alertStyle = .warning
                failed.beginSheetModal(for: window)
            }
        }
    }

    /// The one-time confirmation for command execution over the control
    /// channel. Modal, because the checkbox that asks needs a yes or a no
    /// before it can settle.
    private func confirmCommandExecution() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow panes to run commands in panes they created?"
        alert.informativeText = "A pane that opened another pane through the baia command will be able to run commands in it. That turns a request into an execution in another pane's context. Baia asks once per installation; the answer is kept outside the configuration file, so editing the file by hand does not enable this on its own."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        guard acknowledgement.record() else {
            let failed = NSAlert()
            failed.messageText = "The confirmation could not be saved"
            failed.informativeText = "Baia could not write to its Application Support folder, so command execution stays off."
            failed.alertStyle = .warning
            failed.runModal()
            return false
        }
        return true
    }

    // MARK: - Close routing

    /// ⌘W is Close Pane in the menu bar. With this window key there is no pane
    /// to close and the owner means this window, so the command stops here on
    /// the responder chain, one step before the app delegate it would otherwise
    /// reach. Nothing in a workspace is touched.
    @objc func closePane(_: Any?) {
        close()
    }
}

// MARK: - Editing

extension SettingsWindowController: SettingsEditing {
    var settings: Settings { transactions.settings }

    /// A validation error goes back to the control. Anything else is a file
    /// problem: the banner says what and offers the way out, and the beep says
    /// the edit did not land.
    private func surface(_ failure: SettingsWriteFailure?) -> SettingsValidationError? {
        switch failure {
        case nil:
            return nil
        case let .validation(error)?:
            return error
        case .some:
            refreshRecoveryState()
            NSSound.beep()
            return nil
        }
    }

    func commit(_ edit: SettingsEdit, actionName: String) -> SettingsValidationError? {
        surface(transactions.commit(edit, actionName: actionName))
    }

    func preview(_ edit: SettingsEdit) -> SettingsValidationError? {
        transactions.previewGesture(edit)
    }

    func endGesture(_ edit: SettingsEdit, actionName: String) -> SettingsValidationError? {
        surface(transactions.endGesture(edit, actionName: actionName))
    }
}

// MARK: - Toolbar

extension SettingsWindowController: NSToolbarDelegate {
    private var categoryIdentifiers: [NSToolbarItem.Identifier] {
        SettingsCategory.allCases.map(Self.identifier(for:))
    }

    func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        categoryIdentifiers
    }

    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        categoryIdentifiers
    }

    func toolbarSelectableItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        categoryIdentifiers
    }

    func toolbar(
        _: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool
    ) -> NSToolbarItem? {
        guard let category = SettingsCategory(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = category.title
        item.paletteLabel = category.title
        item.toolTip = category.title
        item.image = NSImage(systemSymbolName: category.symbolName, accessibilityDescription: category.title)
        item.target = self
        item.action = #selector(selectCategory(_:))
        return item
    }
}

// MARK: - Window

extension SettingsWindowController: NSWindowDelegate {
    /// This window's own manager, so the Edit menu's Undo and Redo reverse
    /// settings transactions here and nothing else, and a text field's typing
    /// undo lands on the same stack while the field is being edited.
    func windowWillReturnUndoManager(_: NSWindow) -> UndoManager? {
        settingsUndoManager
    }

    /// The file can change by hand while the window is behind others; the
    /// recovery state is re-read as it comes forward.
    func windowDidBecomeKey(_: Notification) {
        refreshRecoveryState()
    }
}

// MARK: - Recovery banner

/// The persistent recovery state: what is wrong with the file, where it is,
/// and the one way to replace it that keeps the original.
@MainActor
final class SettingsRecoveryBanner: NSView {
    private let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")!)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let reveal = NSButton(title: "Reveal File", target: nil, action: nil)
    private let repair = NSButton(title: "Repair Configuration…", target: nil, action: nil)
    var onReveal: (() -> Void)?
    var onRepair: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.18).cgColor
        icon.contentTintColor = .systemOrange
        message.preferredMaxLayoutWidth = 520
        reveal.target = self
        reveal.action = #selector(revealPressed)
        repair.target = self
        repair.action = #selector(repairPressed)
        let buttons = NSStackView(views: [reveal, repair])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let text = NSStackView(views: [message, buttons])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 8
        let stack = NSStackView(views: [icon, text])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Configuration file problem")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    @objc private func revealPressed() { onReveal?() }
    @objc private func repairPressed() { onRepair?() }

    /// Shows the state, or hides when the file is fine and the last write
    /// landed. Repair is offered only for a file that exists and is broken;
    /// an unreadable file is a permissions problem a new document would not
    /// fix, and a missing one needs no repair.
    func present(state: SettingsDocumentState, failure: SettingsWriteFailure?, fileURL: URL) {
        let path = fileURL.path(percentEncoded: false).replacingOccurrences(
            of: NSHomeDirectory(), with: "~"
        )
        var lines: [String] = []
        var canRepair = false
        switch state {
        case .valid, .missing:
            break
        case .malformed:
            lines.append("\(path) is not valid JSON. Baia keeps the settings it last read and will not write to the file until it is repaired or fixed by hand.")
            canRepair = true
        case .notAnObject:
            lines.append("\(path) is valid JSON but not an object. Baia keeps the settings it last read and will not write to the file until it is repaired or fixed by hand.")
            canRepair = true
        case .unreadable:
            lines.append("\(path) could not be read. Check its permissions.")
        }
        if let failure, lines.isEmpty {
            lines.append("The last change was not saved. \(failure.message)")
        }
        guard !lines.isEmpty else {
            isHidden = true
            return
        }
        message.stringValue = lines.joined(separator: " ")
        repair.isHidden = !canRepair
        isHidden = false
    }
}
