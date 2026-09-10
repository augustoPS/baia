import AppKit
import BaiaSettings
import GhosttyTheme
import PaneChrome

/// One toolbar category's page: a labelled grid of controls, refreshed from
/// the running settings as one unit.
@MainActor
final class SettingsPageController: NSViewController {
    let category: SettingsCategory
    private let grid = NSGridView()
    private(set) var controls: [SettingsControl] = []
    /// Rows whose visibility depends on the settings, with the rule that decides
    /// it. `NSGridRow.isHidden` collapses the row, so a control that means
    /// nothing under the current settings takes no space rather than sitting
    /// disabled with nothing to say for itself.
    private(set) var conditionalRows: [(rows: [NSGridRow], shown: (Settings) -> Bool)] = []
    /// Refreshes that are not a control's: the preview, and the advanced
    /// page's acknowledgement notice.
    private var extraRefreshes: [(Settings) -> Void] = []

    init(category: SettingsCategory) {
        self.category = category
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override func loadView() {
        // Flipped, so a page shorter than the scroll view sits at its top. An
        // unflipped document view in an `NSScrollView` anchors to the bottom
        // and leaves the empty space above the controls.
        let container = FlippedView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 150
        grid.rowAlignment = .firstBaseline
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
        ])
        view = container
    }

    // MARK: - Building

    /// A control with its label, and a caption under it when the label alone
    /// does not say what the control changes.
    @discardableResult
    func row(_ label: String, _ control: SettingsControl, caption: String? = nil) -> [NSGridRow] {
        controls.append(control)
        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        var rows = [grid.addRow(with: [title, control.view])]
        if let caption {
            rows.append(grid.addRow(with: [NSGridCell.emptyContentView, Self.caption(caption)]))
        }
        return rows
    }

    /// A checkbox row: the checkbox carries its own title, so the label column
    /// holds the group's name or nothing.
    @discardableResult
    func toggleRow(_ label: String?, _ control: ToggleControl, caption: String? = nil) -> [NSGridRow] {
        controls.append(control)
        let title = label.map { NSTextField(labelWithString: $0) } ?? NSTextField(labelWithString: "")
        title.alignment = .right
        var rows = [grid.addRow(with: [title, control.view])]
        if let caption {
            rows.append(grid.addRow(with: [NSGridCell.emptyContentView, Self.caption(caption)]))
        }
        return rows
    }

    /// A view spanning both columns: the preview, a notice.
    func fullWidth(_ view: NSView) {
        let row = grid.addRow(with: [view])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.topPadding = 8
    }

    func showRows(_ rows: [NSGridRow], when shown: @escaping (Settings) -> Bool) {
        conditionalRows.append((rows, shown))
    }

    func onRefresh(_ refresh: @escaping (Settings) -> Void) {
        extraRefreshes.append(refresh)
    }

    /// A caption whose text comes from live state outside `Settings`, such as
    /// macOS notification permission. It refreshes with the rest of the page.
    func liveCaption(_ text: @escaping @MainActor () -> String) {
        let label = Self.caption("")
        grid.addRow(with: [NSGridCell.emptyContentView, label])
        onRefresh { _ in label.stringValue = text() }
    }

    static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 400
        return label
    }

    // MARK: - Refreshing

    func refresh(_ settings: Settings) {
        for control in controls {
            control.refresh(settings)
        }
        for (rows, shown) in conditionalRows {
            let hidden = !shown(settings)
            for row in rows where row.isHidden != hidden {
                row.isHidden = hidden
            }
        }
        for refresh in extraRefreshes {
            refresh(settings)
        }
    }
}

/// A view whose origin is its top-left, for a scroll view's document.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Builds the seven pages. Every label, caption and choice title lives here,
/// in product language: what a control changes on screen, never the enum
/// case that spells it in the file.
@MainActor
enum SettingsPages {
    static func make(
        _ category: SettingsCategory,
        editor: SettingsEditing,
        center: ConfigurationCenter,
        acknowledgement: CommandExecutionAcknowledgement,
        preview: SettingsPreviewController?,
        notificationPermission: @escaping @MainActor () -> AttentionNotificationPermission,
        confirmCommandExecution: @escaping () -> Bool
    ) -> SettingsPageController {
        let page = SettingsPageController(category: category)
        switch category {
        case .appearance: appearance(page, editor: editor, center: center, preview: preview)
        case .typography: typography(page, editor: editor)
        case .window: window(page, editor: editor)
        case .workspace: workspace(page, editor: editor)
        case .behavior: behavior(page, editor: editor)
        case .notifications:
            notifications(
                page,
                editor: editor,
                notificationPermission: notificationPermission
            )
        case .advanced: advanced(page, editor: editor, center: center, acknowledgement: acknowledgement, confirm: confirmCommandExecution)
        }
        return page
    }

    /// Every theme name the catalog can resolve, sorted.
    ///
    /// `allThemes` and not `search("")`: the latter filters on
    /// `contains("")`, which with Foundation imported is the range-based
    /// overload and matches nothing.
    private static let themeNames: [String] = GhosttyThemeCatalog.allThemes.map(\.name).sorted()

    private static func appearance(
        _ page: SettingsPageController,
        editor: SettingsEditing,
        center: ConfigurationCenter,
        preview: SettingsPreviewController?
    ) {
        page.row("Theme:", ChoiceControl(
            options: themeNames.map { ChoiceControl.Option(id: $0, title: $0) },
            accessibilityLabel: "Theme",
            actionName: "Change Theme",
            editor: editor,
            read: { $0.themeName },
            edit: { .themeName($0) }
        ), caption: "The terminal's colours. The chrome around each pane follows the theme.")

        page.row("Background:", ColourControl(editor: editor),
                 caption: "Replaces the theme's own background behind the text.")

        page.row("Window material:", ChoiceControl(
            options: ChromeStyle.allCases.map { ChoiceControl.Option(id: $0.rawValue, title: $0.displayName) },
            accessibilityLabel: "Window material",
            actionName: "Change Window Material",
            editor: editor,
            read: { $0.chromeStyle.rawValue },
            edit: { ChromeStyle(rawValue: $0).map { .chromeStyle($0) } }
        ), caption: "Solid is opaque. Liquid Glass and Sheer let the desktop through behind a translucent material; Reduce Transparency in System Settings makes every material solid.")

        let opacityRows = page.row("Opacity:", SliderControl(
            range: 0 ... 1,
            quantum: 0.01,
            accessibilityLabel: "Background opacity",
            actionName: "Change Opacity",
            editor: editor,
            read: { $0.backgroundOpacity },
            edit: { .backgroundOpacity($0) },
            format: { "\(Int(($0 * 100).rounded()))%" }
        ), caption: "How much of the terminal background covers the desktop. Glass protects terminal legibility with a minimum 50% background wash.")
        page.showRows(opacityRows) { $0.chromeStyle.usesBackgroundOpacity }

        page.row("Sidebar:", ChoiceControl(
            options: [
                ChoiceControl.Option(id: SidebarContent.off.rawValue, title: "Hidden"),
                ChoiceControl.Option(id: SidebarContent.files.rawValue, title: "File tree"),
            ],
            accessibilityLabel: "Sidebar",
            actionName: "Change Sidebar",
            editor: editor,
            read: { $0.sidebar.rawValue },
            edit: { SidebarContent(rawValue: $0).map { .sidebar($0) } }
        ), caption: "What the column beside the panes shows when a window opens. Applies to new windows.")

        page.row("Focus colour:", ChoiceControl(
            options: [
                ChoiceControl.Option(id: FocusAccent.accent.rawValue, title: "Theme accent"),
                ChoiceControl.Option(id: FocusAccent.bone.rawValue, title: "Bone (softened foreground)"),
                ChoiceControl.Option(id: FocusAccent.ansi5.rawValue, title: "Magenta (ANSI 5)"),
                ChoiceControl.Option(id: FocusAccent.ansi6.rawValue, title: "Cyan (ANSI 6)"),
                ChoiceControl.Option(id: FocusAccent.twilight.rawValue, title: "Twilight (blue toward magenta)"),
                ChoiceControl.Option(id: FocusAccent.nightshade.rawValue, title: "Nightshade (magenta into the background)"),
                ChoiceControl.Option(id: FocusAccent.sea.rawValue, title: "Sea (cyan toward blue)"),
            ],
            accessibilityLabel: "Focus colour",
            actionName: "Change Focus Colour",
            editor: editor,
            read: { $0.focusAccent.rawValue },
            edit: { FocusAccent.named($0).map { .focusAccent($0) } }
        ), caption: "The colour of the focused pane's name, frame and cursor. Every choice is derived from the theme and repaired for contrast.")

        page.row("Agent attention:", ChoiceControl(
            options: [
                ChoiceControl.Option(id: AttentionStyle.loud.rawValue, title: "Frame the whole pane"),
                ChoiceControl.Option(id: AttentionStyle.quiet.rawValue, title: "Tint the capsule only"),
            ],
            accessibilityLabel: "Agent attention",
            actionName: "Change Agent Attention",
            editor: editor,
            read: { $0.attentionStyle.rawValue },
            edit: { AttentionStyle(rawValue: $0).map { .attentionStyle($0) } }
        ), caption: "How a pane asks for you until you look at it. The frame is findable across a window of panes; the capsule alone is quieter.")

        page.row("Attention colour:", ChoiceControl(
            options: [
                ChoiceControl.Option(id: AttentionAccent.alert.rawValue, title: "Theme alert colour"),
                ChoiceControl.Option(id: AttentionAccent.accent.rawValue, title: "Same as the focus colour"),
            ],
            accessibilityLabel: "Attention colour",
            actionName: "Change Attention Colour",
            editor: editor,
            read: { $0.attentionAccent.rawValue },
            edit: { AttentionAccent(rawValue: $0).map { .attentionAccent($0) } }
        ), caption: "The colour of the frame and the capsule tint. Git conflicts stay in the theme's alert colour either way.")

        let alertRows = page.row("If it matches focus:", ChoiceControl(
            options: [
                ChoiceControl.Option(id: AlertBehavior.stock.rawValue, title: "Use it anyway"),
                ChoiceControl.Option(id: AlertBehavior.noCollision.rawValue, title: "Fall back to the theme alert colour"),
                ChoiceControl.Option(id: AlertBehavior.derive.rawValue, title: "Shift it until it reads apart"),
            ],
            accessibilityLabel: "When attention matches focus",
            actionName: "Change Attention Collision",
            editor: editor,
            read: { $0.alertBehavior.rawValue },
            edit: { AlertBehavior(rawValue: $0).map { .alertBehavior($0) } }
        ), caption: "On this theme the attention colour would be hard to tell from the focus colour or the capsule itself. Shape still separates them: focus is an edge, attention is a fill.")
        // Offered only where it changes something, measured through the same
        // derivation the capsule draws with rather than keyed to a value. See
        // the hub's key decision on `alertBehaviorMatters`.
        page.showRows(alertRows) { settings in
            center.chrome(for: settings).alertBehaviorMatters(for: settings.attentionAccent)
        }

        if let preview {
            page.addChild(preview)
            page.fullWidth(preview.view)
            page.onRefresh { settings in
                preview.sample.apply(
                    settings,
                    appearance: center.appearance(for: settings),
                    windowIsTransparent: center.windowIsTransparent(for: settings)
                )
            }
        }
    }

    private static func typography(_ page: SettingsPageController, editor: SettingsEditing) {
        page.row("Font:", ChoiceControl(
            options: [ChoiceControl.Option(id: "", title: "System default")]
                + installedMonospacedFamilies.map { ChoiceControl.Option(id: $0, title: $0) },
            accessibilityLabel: "Font",
            actionName: "Change Font",
            editor: editor,
            read: { $0.fontFamily ?? "" },
            edit: { .fontFamily($0.isEmpty ? nil : $0) }
        ), caption: "Monospaced families installed on this Mac. System default keeps the terminal's own font. A family the file names that is not installed is listed as itself.")

        page.row("Size:", NumberControl(
            range: Settings.Limits.fontSize,
            step: 0.5,
            fractionDigits: 1,
            unit: "pt",
            accessibilityLabel: "Font size",
            actionName: "Change Font Size",
            editor: editor,
            read: { $0.fontSize },
            edit: { .fontSize($0) }
        ), caption: "Half points are allowed: 11.5 changes how many columns fit a pane.")

        page.row("Cursor:", ChoiceControl(
            options: [
                ChoiceControl.Option(id: CursorStyle.block.rawValue, title: "Block"),
                ChoiceControl.Option(id: CursorStyle.bar.rawValue, title: "Bar"),
                ChoiceControl.Option(id: CursorStyle.underline.rawValue, title: "Underline"),
            ],
            accessibilityLabel: "Cursor",
            actionName: "Change Cursor",
            editor: editor,
            read: { $0.cursorStyle.rawValue },
            edit: { CursorStyle(rawValue: $0).map { .cursorStyle($0) } }
        ))
    }

    /// Families with a fixed-pitch member, by name.
    ///
    /// Read once per page build. Families are tested through their first
    /// member because a family name is not always a font name.
    private static var installedMonospacedFamilies: [String] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let members = manager.availableMembers(ofFontFamily: family),
                  let first = members.first, let name = first.first as? String,
                  let font = NSFont(name: name, size: 12)
            else { return false }
            return font.isFixedPitch
        }.sorted()
    }

    private static func window(_ page: SettingsPageController, editor: SettingsEditing) {
        page.row("Padding:", NumberControl(
            range: Settings.Limits.padding,
            step: 1,
            fractionDigits: 0,
            unit: "pt",
            accessibilityLabel: "Padding",
            actionName: "Change Padding",
            editor: editor,
            read: { $0.windowPadding },
            edit: { .windowPadding($0) }
        ), caption: "Space between a pane's edge and its text. Applies to open and new panes. Changing it can reflow text in open panes.")

        page.toggleRow(nil, ToggleControl(
            title: "Balance padding",
            actionName: "Change Padding Balance",
            editor: editor,
            read: { $0.windowPaddingBalance },
            edit: { .windowPaddingBalance($0) }
        ), caption: "Spreads the leftover pixels of a partial cell evenly, so the text grid stays centred as a pane resizes.")

        page.toggleRow("Keyboard:", ToggleControl(
            title: "Treat Option as Alt",
            actionName: "Change Option Key",
            editor: editor,
            read: { $0.optionAsAlt },
            edit: { .optionAsAlt($0) }
        ), caption: "Keeps Option word jumps working on keyboard layouts where Option composes accented characters.")

        page.toggleRow("At launch:", ToggleControl(
            title: "Restore the previous session",
            actionName: "Change Session Restore",
            editor: editor,
            read: { $0.restoreSession },
            edit: { .restoreSession($0) }
        ), caption: "Reopens the tabs, panes and directories from the last quit.")
    }

    private static func workspace(_ page: SettingsPageController, editor: SettingsEditing) {
        page.row("Project roots:", ProjectRootsControl(editor: editor),
                 caption: "Folders scanned for projects for the command palette. Folders under your home folder are saved as ~ so the file can move between Macs.")

        page.row("Discovery depth:", NumberControl(
            range: Settings.Limits.discoveryDepth,
            step: 1,
            fractionDigits: 0,
            unit: "levels",
            accessibilityLabel: "Discovery depth",
            actionName: "Change Discovery Depth",
            editor: editor,
            read: { Double($0.discoveryMaxDepth) },
            edit: { .discoveryMaxDepth(Int($0.rounded())) }
        ), caption: "How many folder levels below a root a project may sit.")
    }

    private static func behavior(_ page: SettingsPageController, editor: SettingsEditing) {
        page.row("Git status every:", NumberControl(
            range: Settings.Limits.pollSeconds,
            step: 0.25,
            fractionDigits: 2,
            unit: "seconds",
            accessibilityLabel: "Git status interval",
            actionName: "Change Git Interval",
            editor: editor,
            read: { $0.gitPollSeconds },
            edit: { .gitPollSeconds($0) }
        ), caption: "How often each pane reads its repository's branch and changes.")

        page.row("Activity every:", NumberControl(
            range: Settings.Limits.pollSeconds,
            step: 0.25,
            fractionDigits: 2,
            unit: "seconds",
            accessibilityLabel: "Activity interval",
            actionName: "Change Activity Interval",
            editor: editor,
            read: { $0.activityPollSeconds },
            edit: { .activityPollSeconds($0) }
        ), caption: "How often each pane reads what is running in it, which is what labels an agent and marks it busy.")
    }

    private static func notifications(
        _ page: SettingsPageController,
        editor: SettingsEditing,
        notificationPermission: @escaping @MainActor () -> AttentionNotificationPermission
    ) {
        page.toggleRow(nil, ToggleControl(
            title: "Notify when an agent finishes or asks for you",
            actionName: "Change Notifications",
            editor: editor,
            read: { $0.notificationsEnabled },
            edit: { .notificationsEnabled($0) }
        ))
        page.liveCaption {
            let status: String
            switch notificationPermission() {
            case .unknown:
                status = "Baia is waiting for macOS notification permission."
            case .denied:
                status = "macOS is blocking notifications for Baia. Allow them in System Settings › Notifications."
            case .authorized:
                status = "macOS allows notifications for Baia."
            }
            return "Posts a macOS notification for a pane whose window is not in front. The capsule and the window title mark the pane either way. \(status)"
        }
    }

    private static func advanced(
        _ page: SettingsPageController,
        editor: SettingsEditing,
        center: ConfigurationCenter,
        acknowledgement: CommandExecutionAcknowledgement,
        confirm: @escaping () -> Bool
    ) {
        page.toggleRow("Control channel:", ToggleControl(
            title: "Answer requests from panes",
            actionName: "Change Control Channel",
            editor: editor,
            read: { $0.controlChannelEnabled },
            edit: { .controlChannelEnabled($0) }
        ), caption: "Lets the baia command inside a pane split, focus, read and close the panes it created. Off keeps the socket and answers every request as disabled.")

        page.toggleRow(nil, ToggleControl(
            title: "Allow reading the screens of panes a pane created",
            actionName: "Change Read Permission",
            editor: editor,
            read: { $0.controlAllowRead },
            edit: { .controlAllowRead($0) }
        ), caption: "The one answer that carries another pane's text, including whatever you typed into it.")

        let run = ToggleControl(
            title: "Allow running commands in panes a pane created",
            actionName: "Change Command Execution",
            editor: editor,
            read: { $0.controlAllowRun },
            edit: { .controlAllowRun($0) }
        )
        run.confirmEnabling = {
            acknowledgement.isAcknowledged || confirm()
        }
        page.toggleRow(nil, run, caption: "Turns a request into an execution in another pane's context. Off by default. Baia asks you to confirm once per installation before it takes effect.")

        // The file can say yes without this Mac having confirmed; the channel
        // then keeps `run` off. The notice says so and offers the confirmation
        // here rather than leaving the switch on with nothing happening.
        let notice = SettingsPageController.caption(
            "The configuration file enables command execution, but this Mac has not confirmed it, so it stays off."
        )
        notice.textColor = .systemOrange
        let confirmButton = NSButton(title: "Confirm Command Execution…", target: nil, action: nil)
        let handler = ConfirmationHandler(confirm: confirm, acknowledgement: acknowledgement, center: center)
        confirmButton.target = handler
        confirmButton.action = #selector(ConfirmationHandler.confirmPressed)
        let noticeStack = NSStackView(views: [notice, confirmButton])
        noticeStack.orientation = .vertical
        noticeStack.alignment = .leading
        noticeStack.spacing = 6
        page.fullWidth(noticeStack)
        page.onRefresh { settings in
            noticeStack.isHidden = !(settings.controlAllowRun && !acknowledgement.isAcknowledged)
            _ = handler
        }
    }

    /// Target for the notice's button. A class rather than a closure because
    /// `NSButton` wants an Objective-C selector.
    @MainActor
    private final class ConfirmationHandler: NSObject {
        private let confirm: () -> Bool
        private let acknowledgement: CommandExecutionAcknowledgement
        private let center: ConfigurationCenter

        init(confirm: @escaping () -> Bool, acknowledgement: CommandExecutionAcknowledgement, center: ConfigurationCenter) {
            self.confirm = confirm
            self.acknowledgement = acknowledgement
            self.center = center
        }

        @objc func confirmPressed() {
            guard confirm() else { return }
            // Nothing in the file changed, but what the control server may
            // offer did: the delegate re-reads the acknowledgement on this.
            center.announce()
        }
    }
}
