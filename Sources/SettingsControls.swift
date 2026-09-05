import AppKit
import BaiaSettings
import PaneChrome

/// What a control needs from the window: the running value to read and one
/// path to write through.
///
/// Every write goes to `SettingsTransactionController` behind this; the
/// protocol exists so a control never sees the file, the undo manager or the
/// recovery banner. A validation error comes back to the control, which shows
/// it beside itself and keeps its text; every other failure is the window's to
/// show and the control hears nothing.
@MainActor
protocol SettingsEditing: AnyObject {
    var settings: Settings { get }
    func commit(_ edit: SettingsEdit, actionName: String) -> SettingsValidationError?
    func preview(_ edit: SettingsEdit) -> SettingsValidationError?
    func endGesture(_ edit: SettingsEdit, actionName: String) -> SettingsValidationError?
}

/// One control on a page: a view, and a refresh from the running settings.
@MainActor
protocol SettingsControl: AnyObject {
    var view: NSView { get }
    func refresh(_ settings: Settings)
}

/// The shared shape: a line of widgets with an error line under it that is
/// hidden until a validation error arrives and cleared by the next valid edit.
@MainActor
class SettingsControlBase: NSObject, SettingsControl {
    let stack = NSStackView()
    var view: NSView { stack }
    let line = NSStackView()
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    unowned let editor: SettingsEditing

    init(editor: SettingsEditing) {
        self.editor = editor
        super.init()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = 8
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.preferredMaxLayoutWidth = 380
        stack.addArrangedSubview(line)
        stack.addArrangedSubview(errorLabel)
    }

    func refresh(_: Settings) {}

    /// True while this control holds text the file refused. A refresh leaves
    /// the text alone in that state, which is what "retains the visible invalid
    /// value" means for a field the owner is still correcting.
    var hasError: Bool { !errorLabel.isHidden }

    func show(_ error: SettingsValidationError?) {
        guard let error else {
            errorLabel.isHidden = true
            errorLabel.stringValue = ""
            return
        }
        errorLabel.stringValue = error.message
        errorLabel.isHidden = false
    }
}

// MARK: - Choice

/// A popup over a fixed set of spellings.
///
/// Keyed by a string id rather than a generic value, so the class can carry an
/// `@objc` action. Enum controls pass the raw value as the id and rebuild the
/// case in `edit`.
@MainActor
final class ChoiceControl: SettingsControlBase {
    struct Option {
        let id: String
        let title: String
    }

    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var options: [Option]
    private let read: (Settings) -> String
    private let edit: (String) -> SettingsEdit?
    private let actionName: String

    init(
        options: [Option],
        accessibilityLabel: String,
        actionName: String,
        editor: SettingsEditing,
        read: @escaping (Settings) -> String,
        edit: @escaping (String) -> SettingsEdit?
    ) {
        self.options = options
        self.read = read
        self.edit = edit
        self.actionName = actionName
        super.init(editor: editor)
        popup.addItems(withTitles: options.map(\.title))
        popup.target = self
        popup.action = #selector(changed)
        popup.setAccessibilityLabel(accessibilityLabel)
        popup.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        line.addArrangedSubview(popup)
    }

    @objc private func changed() {
        let index = popup.indexOfSelectedItem
        guard options.indices.contains(index), let edit = edit(options[index].id) else { return }
        show(editor.commit(edit, actionName: actionName))
    }

    override func refresh(_ settings: Settings) {
        let current = read(settings)
        if let index = options.firstIndex(where: { $0.id == current }) {
            popup.selectItem(at: index)
        } else {
            // A value the file carries that this list does not offer, such as a
            // font that is not installed. Shown as itself rather than snapped to
            // the first item, so the control never claims a value the file does
            // not hold.
            options.append(Option(id: current, title: current))
            popup.addItem(withTitle: current)
            popup.selectItem(at: options.count - 1)
        }
    }
}

// MARK: - Toggle

@MainActor
final class ToggleControl: SettingsControlBase {
    private let checkbox: NSButton
    private let read: (Settings) -> Bool
    private let edit: (Bool) -> SettingsEdit
    private let actionName: String

    /// Asked before an edit that turns the switch on. Answering false puts the
    /// switch back and writes nothing: the command-execution confirmation.
    var confirmEnabling: (() -> Bool)?

    init(
        title: String,
        actionName: String,
        editor: SettingsEditing,
        read: @escaping (Settings) -> Bool,
        edit: @escaping (Bool) -> SettingsEdit
    ) {
        checkbox = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        self.read = read
        self.edit = edit
        self.actionName = actionName
        super.init(editor: editor)
        checkbox.target = self
        checkbox.action = #selector(changed)
        line.addArrangedSubview(checkbox)
    }

    @objc private func changed() {
        let on = checkbox.state == .on
        if on, let confirmEnabling, !confirmEnabling() {
            checkbox.state = .off
            return
        }
        show(editor.commit(edit(on), actionName: actionName))
    }

    override func refresh(_ settings: Settings) {
        checkbox.state = read(settings) ? .on : .off
    }
}

// MARK: - Text

/// A text field that commits on an editing boundary: Return, Tab, or focus
/// leaving the field. Never on a keystroke.
@MainActor
final class TextControl: SettingsControlBase, NSTextFieldDelegate {
    let field = NSTextField()
    private let read: (Settings) -> String
    private let edit: (String) -> SettingsEdit
    private let actionName: String

    init(
        placeholder: String?,
        width: Double,
        accessibilityLabel: String,
        actionName: String,
        editor: SettingsEditing,
        read: @escaping (Settings) -> String,
        edit: @escaping (String) -> SettingsEdit
    ) {
        self.read = read
        self.edit = edit
        self.actionName = actionName
        super.init(editor: editor)
        field.placeholderString = placeholder
        field.delegate = self
        field.setAccessibilityLabel(accessibilityLabel)
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        line.addArrangedSubview(field)
    }

    private var isEditing: Bool {
        field.currentEditor() != nil
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitText()
        // The field editor's typing undo lives on the window's manager while
        // the field is being edited and comes off it here, so ⌘Z after Return
        // reverses the transaction the text produced rather than the keystrokes
        // that produced the text.
        if let editorView = notification.userInfo?["NSFieldEditor"] as? NSTextView {
            field.window?.undoManager?.removeAllActions(withTarget: editorView)
        }
    }

    private func commitText() {
        show(editor.commit(edit(field.stringValue), actionName: actionName))
    }

    override func refresh(_ settings: Settings) {
        // Invalid text stays until the owner corrects it; a field mid-edit is
        // left to the owner as well, so an external change cannot replace what
        // is being typed.
        guard !hasError, !isEditing else { return }
        field.stringValue = read(settings)
    }
}

// MARK: - Number

/// A number field with a stepper beside it, bounded by the file's own range.
///
/// The field parses in the user's locale and shows the validation message the
/// file would give, so 3 for a font size says "between 4 and 72" rather than
/// silently clamping. The stepper moves by `step` and clamps to the range,
/// since a click cannot mean a typo.
@MainActor
final class NumberControl: SettingsControlBase, NSTextFieldDelegate {
    private let field = NSTextField()
    private let stepper = NSStepper()
    private let unit = NSTextField(labelWithString: "")
    private let read: (Settings) -> Double
    private let edit: (Double) -> SettingsEdit
    private let actionName: String
    private let range: ClosedRange<Double>
    private let fractionDigits: Int
    private let formatter = NumberFormatter()

    init(
        range: ClosedRange<Double>,
        step: Double,
        fractionDigits: Int,
        unit unitText: String,
        accessibilityLabel: String,
        actionName: String,
        editor: SettingsEditing,
        read: @escaping (Settings) -> Double,
        edit: @escaping (Double) -> SettingsEdit
    ) {
        self.read = read
        self.edit = edit
        self.actionName = actionName
        self.range = range
        self.fractionDigits = fractionDigits
        super.init(editor: editor)
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractionDigits
        field.delegate = self
        field.alignment = .right
        field.setAccessibilityLabel(accessibilityLabel)
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        stepper.minValue = range.lowerBound
        stepper.maxValue = range.upperBound
        stepper.increment = step
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepped)
        stepper.setAccessibilityLabel(accessibilityLabel)
        unit.stringValue = unitText
        unit.textColor = .secondaryLabelColor
        line.addArrangedSubview(field)
        line.addArrangedSubview(stepper)
        line.addArrangedSubview(unit)
    }

    @objc private func stepped() {
        let value = min(max(stepper.doubleValue, range.lowerBound), range.upperBound)
        field.stringValue = formatter.string(from: value as NSNumber) ?? "\(value)"
        show(editor.commit(edit(value), actionName: actionName))
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let value = formatter.number(from: field.stringValue.trimmingCharacters(in: .whitespaces))?.doubleValue else {
            show(SettingsValidationError(key: edit(0).key, message: "Enter a number."))
            return
        }
        // Validate before invoking edit: integer-backed controls must never
        // convert an unbounded Double to Int.
        let key = edit(0).key
        guard value.isFinite, range.contains(value) else {
            show(SettingsValidationError(key: key, message: "Enter a number between \(range.lowerBound) and \(range.upperBound)."))
            return
        }
        guard key != .discoveryMaxDepth || value == value.rounded() else {
            show(SettingsValidationError(key: key, message: "Enter a whole number of levels."))
            return
        }
        show(editor.commit(edit(value), actionName: actionName))
        if let editorView = notification.userInfo?["NSFieldEditor"] as? NSTextView {
            field.window?.undoManager?.removeAllActions(withTarget: editorView)
        }
    }

    override func refresh(_ settings: Settings) {
        let value = read(settings)
        stepper.doubleValue = value
        guard !hasError, field.currentEditor() == nil else { return }
        field.stringValue = formatter.string(from: value as NSNumber) ?? "\(value)"
    }
}

// MARK: - Slider

/// A continuous control. Each drag frame previews; the mouse-up writes once and
/// registers one undo step back to where the drag began.
///
/// The gesture boundary is read off the event that delivered the action:
/// AppKit sends a continuous slider's action for the mouse-down, every drag
/// and the mouse-up, and only the last is a boundary. A keyboard change (arrow
/// keys on the focused slider) arrives on a key event and is committed whole.
@MainActor
final class SliderControl: SettingsControlBase {
    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    private let read: (Settings) -> Double
    private let edit: (Double) -> SettingsEdit
    private let format: (Double) -> String
    private let actionName: String
    private let quantum: Double

    init(
        range: ClosedRange<Double>,
        quantum: Double,
        accessibilityLabel: String,
        actionName: String,
        editor: SettingsEditing,
        read: @escaping (Settings) -> Double,
        edit: @escaping (Double) -> SettingsEdit,
        format: @escaping (Double) -> String
    ) {
        self.read = read
        self.edit = edit
        self.format = format
        self.actionName = actionName
        self.quantum = quantum
        super.init(editor: editor)
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(moved)
        slider.setAccessibilityLabel(accessibilityLabel)
        slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true
        line.addArrangedSubview(slider)
        line.addArrangedSubview(valueLabel)
    }

    /// Snapped to `quantum`, so a drag cannot write `0.6008831521739131` into a
    /// file meant to be read and edited by hand.
    private var snappedValue: Double {
        (slider.doubleValue / quantum).rounded() * quantum
    }

    @objc private func moved() {
        let value = snappedValue
        valueLabel.stringValue = format(value)
        let type = NSApp.currentEvent?.type
        if type == .leftMouseDown || type == .leftMouseDragged {
            show(editor.preview(edit(value)))
        } else {
            show(editor.endGesture(edit(value), actionName: actionName))
        }
    }

    override func refresh(_ settings: Settings) {
        let value = read(settings)
        slider.doubleValue = value
        valueLabel.stringValue = format(value)
    }
}

// MARK: - Colour

/// A colour well beside a hex field. Both write the same key; the well always
/// produces a valid hex, the field is validated and keeps its text when it is
/// not one.
@MainActor
final class ColourControl: SettingsControlBase, NSTextFieldDelegate {
    private let well = NSColorWell()
    private let field = NSTextField()
    private let actionName = "Change Background Colour"

    override init(editor: SettingsEditing) {
        super.init(editor: editor)
        // Centred rather than on the first baseline: the well has no text, so
        // baseline alignment drops it below the field beside it.
        line.alignment = .centerY
        well.colorWellStyle = .minimal
        well.target = self
        well.action = #selector(picked)
        well.setAccessibilityLabel("Background colour")
        field.placeholderString = "#141414"
        field.delegate = self
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.setAccessibilityLabel("Background colour, hex")
        field.widthAnchor.constraint(equalToConstant: 96).isActive = true
        line.addArrangedSubview(well)
        line.addArrangedSubview(field)
    }

    @objc private func picked() {
        guard let colour = well.color.usingColorSpace(.sRGB) else { return }
        let hex = String(
            format: "#%02x%02x%02x",
            Int((colour.redComponent * 255).rounded()),
            Int((colour.greenComponent * 255).rounded()),
            Int((colour.blueComponent * 255).rounded())
        )
        // A drag inside the colour panel arrives as a stream of actions. Each
        // one is a valid colour, so they preview and the panel's mouse-up
        // writes, exactly as the slider does.
        let type = NSApp.currentEvent?.type
        if type == .leftMouseDown || type == .leftMouseDragged {
            show(editor.preview(.backgroundHex(hex)))
        } else {
            show(editor.endGesture(.backgroundHex(hex), actionName: actionName))
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        show(editor.commit(.backgroundHex(field.stringValue), actionName: actionName))
        if let editorView = notification.userInfo?["NSFieldEditor"] as? NSTextView {
            field.window?.undoManager?.removeAllActions(withTarget: editorView)
        }
    }

    override func refresh(_ settings: Settings) {
        if let rgb = RGB(hex: settings.backgroundHex) {
            well.color = NSColor(
                srgbRed: CGFloat(rgb.red),
                green: CGFloat(rgb.green),
                blue: CGFloat(rgb.blue),
                alpha: 1
            )
        }
        guard !hasError, field.currentEditor() == nil else { return }
        field.stringValue = settings.backgroundHex
    }
}

// MARK: - Project roots

/// The list editor for project roots: add through a folder panel, remove,
/// reorder by dragging or with the arrows. Every change is one transaction and
/// one undo step.
///
/// Shows the resolved path, which is what the file tree and the discovery walk
/// use; the file keeps the `~` spelling for anything under the home folder,
/// which `SettingsEdit` restores on the way out.
@MainActor
final class ProjectRootsControl: SettingsControlBase, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let addButton = NSButton(title: "Add…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let upButton = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Move up")!, target: nil, action: nil)
    private let downButton = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Move down")!, target: nil, action: nil)
    private var roots: [String] = []
    private let actionName = "Change Project Roots"
    private static let rowType = NSPasteboard.PasteboardType("pasqualotto.baia.settings.project-root-row")

    override init(editor: SettingsEditing) {
        super.init(editor: editor)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        column.title = "Folder"
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true
        table.registerForDraggedTypes([Self.rowType])
        table.setAccessibilityLabel("Project roots")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 380).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        addButton.target = self
        addButton.action = #selector(add)
        removeButton.target = self
        removeButton.action = #selector(remove)
        upButton.target = self
        upButton.action = #selector(moveUp)
        downButton.target = self
        downButton.action = #selector(moveDown)
        upButton.setAccessibilityLabel("Move project root up")
        downButton.setAccessibilityLabel("Move project root down")
        let buttons = NSStackView(views: [addButton, removeButton, upButton, downButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6

        line.orientation = .vertical
        line.alignment = .leading
        line.addArrangedSubview(scroll)
        line.addArrangedSubview(buttons)
        updateButtons()
    }

    private func commit(_ next: [String]) {
        show(editor.commit(.projectRoots(next), actionName: actionName))
    }

    @objc private func add() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to scan for projects."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            let added = panel.urls.map { $0.path(percentEncoded: false) }
                .filter { !roots.contains($0) }
            guard !added.isEmpty else { return }
            commit(roots + added)
        }
    }

    @objc private func remove() {
        let row = table.selectedRow
        guard roots.indices.contains(row) else { return }
        var next = roots
        next.remove(at: row)
        commit(next)
    }

    @objc private func moveUp() {
        move(table.selectedRow, to: table.selectedRow - 1)
    }

    @objc private func moveDown() {
        move(table.selectedRow, to: table.selectedRow + 1)
    }

    private func move(_ from: Int, to: Int) {
        guard roots.indices.contains(from), roots.indices.contains(to) else { return }
        var next = roots
        next.swapAt(from, to)
        commit(next)
        table.selectRowIndexes([to], byExtendingSelection: false)
    }

    private func updateButtons() {
        let row = table.selectedRow
        removeButton.isEnabled = roots.indices.contains(row)
        upButton.isEnabled = row > 0
        downButton.isEnabled = row >= 0 && row < roots.count - 1
    }

    override func refresh(_ settings: Settings) {
        guard settings.projectRoots != roots else { return }
        let selected = table.selectedRow
        roots = settings.projectRoots
        table.reloadData()
        if roots.indices.contains(selected) {
            table.selectRowIndexes([selected], byExtendingSelection: false)
        }
        updateButtons()
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in _: NSTableView) -> Int {
        roots.count
    }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: (roots[row] as NSString).abbreviatingWithTildeInPath)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = roots[row]
        return label
    }

    func tableViewSelectionDidChange(_: Notification) {
        updateButtons()
    }

    func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(
        _: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow _: Int,
        proposedDropOperation operation: NSTableView.DropOperation
    ) -> NSDragOperation {
        operation == .above && info.draggingPasteboard.availableType(from: [Self.rowType]) != nil ? .move : []
    }

    func tableView(
        _: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation _: NSTableView.DropOperation
    ) -> Bool {
        guard let text = info.draggingPasteboard.string(forType: Self.rowType),
              let from = Int(text), roots.indices.contains(from)
        else { return false }
        var next = roots
        let moved = next.remove(at: from)
        let target = from < row ? row - 1 : row
        next.insert(moved, at: min(max(target, 0), next.count))
        guard next != roots else { return false }
        commit(next)
        return true
    }
}
