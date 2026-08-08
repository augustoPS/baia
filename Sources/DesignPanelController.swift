#if DEBUG

    import AppKit
    import BaiaSettings

    /// A floating panel that refuses key unless something in it explicitly asks,
    /// so a slider drag cannot pull the keyboard out of the pane being dialled.
    ///
    /// `.nonactivatingPanel` in the style mask is what keeps clicking this panel
    /// from activating the app, and ``canBecomeKey`` returning false is what keeps
    /// the click from moving key away from whatever window had it. The two are
    /// separate mechanisms and both are needed: the style mask governs
    /// *application* activation, the overrides govern *window* key status, and a
    /// nonactivating panel that still accepted key would steal the keyboard from a
    /// pane inside the same, already-active app — which is the whole failure this
    /// panel exists to avoid, because the app being dialled is the one running the
    /// owner's agents.
    ///
    /// ## The one exception, and why it is not a hole
    ///
    /// A window that can never become key contains an `NSTextField` that can never
    /// be typed into, and two of the ink knobs are hex fields. So key is not
    /// refused absolutely — it is refused *by default*, and ``wantsKey`` is the
    /// opt-in a hex field raises for the duration of its own editing session.
    ///
    /// That is a narrower thing than it sounds, and deliberately narrower than
    /// simply returning true:
    ///
    /// - **Only a hex field ever sets it.** Sliders, checkboxes, segmented
    ///   controls and popups all work in a non-key window, so none of them asks,
    ///   and the drag that the acceptance criterion is about therefore cannot
    ///   reach this flag at all.
    /// - **It is raised on an explicit click into a field**, which is a person
    ///   deciding to type here, not a side effect of dialling. Taking key when
    ///   asked is what every window does; the failure being guarded is taking it
    ///   when *not* asked.
    /// - **It is lowered on ``resignKey()`` and ``orderOut(_:)``**, which is a
    ///   window-level fact rather than a control-level one, and that is the whole
    ///   point. See below.
    ///
    /// ## Lowering has to be structural, and was not at first
    ///
    /// The first version lowered the flag only in the hex field's end-of-editing
    /// action, and **that leaked on two ordinary paths**: pressing Escape aborts
    /// the field editor without firing an action at all, and closing the panel
    /// mid-edit (⌥⌘D, or the close button) orders it out with no action either.
    /// After either, the panel answered `canBecomeKey = true` indefinitely, and
    /// the *next* click — a slider drag included — would have taken key from the
    /// pane. That is precisely the property this design exists to protect, undone
    /// by the mechanism meant to protect it.
    ///
    /// So the lowering moved onto the window. ``resignKey()`` is the honest hook:
    /// the panel is no longer key, therefore the editing session it took key for
    /// is over, whatever ended it and whether or not any control noticed.
    /// ``orderOut(_:)`` covers being ordered out. The hex field's own lowering
    /// stays as a harmless fast path.
    ///
    /// **The close button is covered twice, and that was measured rather than
    /// assumed.** ⌥⌘D reaches `orderOut` directly, but the titlebar button drives
    /// `performClose(_:)` → `close()`, which is a different entry point and could
    /// plausibly have bypassed both hooks. A probe on a `.titled`/`.closable`
    /// nonactivating panel showed `close()` and `performClose(_:)` each calling
    /// `orderOut(_:)` *and* firing `resignKey()`, in that order. So no close path
    /// leaves the flag raised, and neither override is redundant: `resignKey`
    /// alone would miss ordering out a panel that was never key, and `orderOut`
    /// alone would miss Escape and click-away, which end editing without closing
    /// anything.
    ///
    /// **Two hex fields in a row read as a bug and are not one.** Clicking field
    /// B while A is editing runs B's `mouseDown` — and its `makeKey` — before A's
    /// end-of-editing action lowers the flag, so the flag is briefly lowered by A
    /// after B raised it. Harmless: the panel is *already key* at that moment, so
    /// `canBecomeKey` is not consulted, and B's editing session proceeds. The
    /// flag is re-consulted only on the next click that arrives while the panel
    /// is not key, and by then `resignKey` has run.
    ///
    /// `canBecomeMain` stays false unconditionally: main is what the menu bar
    /// validates against, and handing it to this panel would grey out every
    /// command in the bar while it is open. `PalettePanel` refuses main for the
    /// same reason.
    final class DesignPanel: NSPanel {
        /// Raised by a hex field for the length of its editing session. See the
        /// class doc.
        var wantsKey = false

        override var canBecomeKey: Bool { wantsKey }

        override var canBecomeMain: Bool { false }

        /// The panel is no longer key, so whatever editing session took key is
        /// over. Covers Escape, clicking away, and ⌘Tab alike — none of which
        /// fires a control action. See the class doc.
        override func resignKey() {
            super.resignKey()
            wantsKey = false
        }

        /// Closed, possibly mid-edit and possibly while still key, where
        /// ``resignKey()`` may not run. Lowered before `super` so the flag is
        /// already down for anything the ordering-out triggers.
        override func orderOut(_ sender: Any?) {
            wantsKey = false
            super.orderOut(sender)
        }
    }

    /// The debug design panel: every ``BaiaSettings/DesignOverrides`` knob as a
    /// live control, over a running app.
    ///
    /// ## The trip-wire, and how this complies
    ///
    /// `ConfigurationCenter.onSettingsChange` has no unregister (its own doc
    /// comment says so and says why), so **every registration is permanent and
    /// this object registers exactly once.** Compliance is structural rather than
    /// conventional:
    ///
    /// - This controller is created once, by `AppDelegate`'s `lazy var`, and is
    ///   never rebuilt — unlike `SettingsWindowController`, which is deliberately
    ///   rebuilt per ⌘, and which is the consumer whose dead entries that doc
    ///   comment accounts for. Toggling this panel orders a window in and out; it
    ///   constructs nothing.
    /// - The registration happens in ``init``, which runs once per instance,
    ///   rather than in a `show`/`toggle` path that runs per keystroke.
    ///
    /// A second instance would be a second permanent handler and a second window
    /// writing the same `designOverrides`, so the `lazy var` is not a convenience
    /// here, it is the enforcement.
    ///
    /// ## What the handler is for, and what it is not
    ///
    /// The handler re-reads the center and refreshes the controls. It exists for
    /// the writes this panel did not make: the settings file being edited under a
    /// running app, and the appearance flipping. It deliberately does **not** carry
    /// a value back into `designOverrides`, so there is no loop — the panel's own
    /// write fires the handler, and the handler re-reads what the panel just wrote.
    ///
    /// ``isRefreshing`` guards the return leg of exactly that path. ``refresh()``
    /// writes into every control, and ``commit()`` refuses to write to the center
    /// while it runs, so a control that reacts to being *set* cannot push its own
    /// value back out. AppKit fires no action for a programmatic assignment today,
    /// which makes the guard belt-and-braces rather than load-bearing — and it is
    /// kept because the cost is one boolean and the failure it prevents is a write
    /// loop between the panel and the center, which shows up as a spinning app
    /// rather than as anything on screen. A later row builder wiring a control
    /// that *does* emit on assignment is covered without having to notice this.
    ///
    /// ## Nothing here persists
    ///
    /// No `UserDefaults`, no `NSWindow.setFrameAutosaveName`, no write to the
    /// settings file. The panel opens in the same place with everything nil on
    /// every launch, which is what ``BaiaSettings/DesignOverrides`` means by a dial
    /// being a question rather than an answer. Copy Values is the only way a dialled
    /// value leaves the process, and it leaves as text for a human to read.
    @MainActor
    final class DesignPanelController: NSObject {
        private let center: ConfigurationCenter

        private let panel: DesignPanel

        /// The value being edited. Written to the center on every control event,
        /// held here so a control can move one field without rebuilding the other
        /// thirty from the UI.
        ///
        /// Starts empty rather than from `center.designOverrides`, which is nil at
        /// construction and can only have been made non-nil by this same object.
        private var overrides = DesignOverrides()

        /// True while ``refresh()`` is writing values into controls, so that
        /// ``commit()`` refuses to write to the center for the duration.
        ///
        /// No control wired here emits on a programmatic assignment today, so this
        /// guards a loop that cannot currently form. See the class doc for why it
        /// is kept anyway.
        private var isRefreshing = false

        /// Every control that has to be re-read from ``overrides`` on a refresh,
        /// keyed by nothing: each closure knows its own control and its own field.
        ///
        /// A list of closures rather than a stored reference per control, because
        /// there are thirty-one rows and a property per control would be thirty-one
        /// lines of boilerplate whose only reader is one loop.
        private var refreshers: [() -> Void] = []

        var isVisible: Bool { panel.isVisible }

        init(center: ConfigurationCenter) {
            self.center = center
            panel = DesignPanel(
                contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 620),
                // `.titled` so the panel can be identified and moved, `.closable`
                // so it can be dismissed without the shortcut, `.utilityWindow` for
                // the narrow title bar a tool panel wears, `.resizable` because the
                // control stack is taller than most screens want to give it, and
                // `.nonactivatingPanel` for the reason the class doc gives.
                styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            super.init()

            panel.title = "Design"
            panel.isFloatingPanel = true
            panel.level = .floating
            // False, against the palette's true. The palette is modal-ish and
            // should vanish when the app is left; this is a reference surface the
            // owner leaves up while looking at the app, and hiding it on deactivate
            // would hide it every time he clicked into something else to compare.
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.animationBehavior = .none
            // Never restored, never autosaved: see the class doc on persistence.
            panel.isRestorable = false

            panel.contentView = makeContent()

            // Exactly once, in init. See the class doc's trip-wire section.
            center.onSettingsChange { [weak self] in self?.refresh() }
        }

        // MARK: - Presenting

        /// Shows the panel, or hides it when it is already up.
        ///
        /// `orderFront` and never `makeKeyAndOrderFront`. The palette's own
        /// `present` calls the latter because it is typed into; calling it here
        /// would hand the keyboard to a panel that refuses it by default
        /// (``DesignPanel/wantsKey`` is false at this point, so AppKit would leave
        /// key where it was) and would still be a line a later reader could "fix"
        /// into a real steal. There is no `NSApp.activate` here either, for the
        /// same reason `showSettings` needs one and this does not: activating the
        /// app to show a panel is exactly the interruption a nonactivating panel
        /// avoids.
        ///
        /// **The panel's only `makeKey` is in ``HexField/mouseDown(with:)``**, and
        /// it is reached only by a click into a hex field. Opening the panel,
        /// dialling any slider, and toggling any switch all run without one.
        func toggle() {
            if panel.isVisible {
                panel.orderOut(nil)
            } else {
                refresh()
                if panel.frame.origin == .zero { positionAtTopRight() }
                panel.orderFront(nil)
            }
        }

        /// Top-right of the main screen's visible frame, computed once on the
        /// first open. Not saved: the panel returns here next launch, which is the
        /// no-persistence rule applying to geometry as well as to values.
        private func positionAtTopRight() {
            guard let screen = NSScreen.main else { return }
            let visible = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(
                NSPoint(
                    x: visible.maxX - size.width - 20,
                    y: visible.maxY - size.height - 20
                )
            )
        }

        // MARK: - Writing

        /// The one write path into the center.
        ///
        /// Every control event lands here, which is what lets the class doc say the
        /// panel writes a whole value per event: the center's `designOverrides`
        /// setter is documented to fire unconditionally and to rely on each
        /// consumer's own equality guard, so nothing here tries to diff first.
        private func commit() {
            guard !isRefreshing else { return }
            center.designOverrides = overrides
        }

        /// Re-reads every control from ``overrides``.
        ///
        /// Guarded by ``isRefreshing`` so a control that emits on a programmatic
        /// write cannot re-enter ``commit()``. See the class doc.
        private func refresh() {
            isRefreshing = true
            for refresher in refreshers { refresher() }
            isRefreshing = false
        }

        // MARK: - Reset and Copy

        /// Clears every dial and returns the app to what the config file says.
        ///
        /// `nil` rather than an empty `DesignOverrides()`, which would render
        /// identically (`Settings.applying(_:)` on an empty value is the identity)
        /// but would leave the center on its composed path forever. The center's
        /// `effectiveSettings` short-circuits on nil, and Reset means "stop
        /// overriding", not "override with nothing".
        @objc private func resetAll() {
            overrides = DesignOverrides()
            center.designOverrides = nil
            refresh()
        }

        /// Puts the dialled values on the clipboard as commented JSON.
        ///
        /// That text is also the format of `~/.config/baia/design-overrides.json`,
        /// the file `ConfigurationCenter` watches, so a paste of this straight into
        /// it is picked up on save and re-themes the running app. The app never
        /// writes that file, and this pasteboard write is the only place a dialled
        /// value is serialised at all.
        @objc private func copyValues() {
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(DesignOverridesText.commentedJSON(overrides), forType: .string)
        }

        // MARK: - Layout

        private static let width: CGFloat = 420

        private func makeContent() -> NSView {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
            stack.translatesAutoresizingMaskIntoConstraints = false

            buildSettingsShadows(into: stack)
            buildLift(into: stack)
            buildRim(into: stack)
            buildInks(into: stack)
            buildMaterials(into: stack)
            buildWindow(into: stack)

            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            let documentView = NSView()
            documentView.translatesAutoresizingMaskIntoConstraints = false
            documentView.addSubview(stack)
            scroll.documentView = documentView

            let buttons = NSStackView(views: [makeButton("Reset", #selector(resetAll)),
                                              makeButton("Copy Values", #selector(copyValues))])
            buttons.orientation = .horizontal
            buttons.spacing = 8
            buttons.translatesAutoresizingMaskIntoConstraints = false

            let root = NSView()
            root.addSubview(scroll)
            root.addSubview(buttons)

            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: documentView.topAnchor),
                stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
                documentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

                scroll.topAnchor.constraint(equalTo: root.topAnchor),
                scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),

                buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
                buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            ])
            return root
        }

        private func makeButton(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            return button
        }

        // MARK: - Groups

        /// The seven that shadow a ``BaiaSettings/Settings`` field.
        ///
        /// Grouped together and first, because these are the only knobs here whose
        /// dialled answer has somewhere to go: each one names a real config key, so
        /// "this looks right" ends in an edit to `~/.config/baia/config.json`. The
        /// extras below have no such destination and end in a constant or in
        /// nothing.
        private func buildSettingsShadows(into stack: NSStackView) {
            stack.addArrangedSubview(makeHeader("Settings shadows"))
            addSlider(
                to: stack, label: "Background opacity", range: 0 ... 1, step: 0.01,
                get: { $0.backgroundOpacity }, set: { $0.backgroundOpacity = $1 }
            )
            addToggle(
                to: stack, label: "Background blur",
                get: { $0.backgroundBlur }, set: { $0.backgroundBlur = $1 }
            )
            addChoice(
                to: stack, label: "Chrome style", cases: ChromeStyle.allCases,
                get: { $0.chromeStyle }, set: { $0.chromeStyle = $1 },
                help: "Reduce Transparency still forces flat downstream, so dialling glass on a machine with the flag set changes the setting and correctly changes nothing on screen."
            )
            addChoice(
                to: stack, label: "Attention style", cases: AttentionStyle.allCases,
                get: { $0.attentionStyle }, set: { $0.attentionStyle = $1 }
            )
            addChoice(
                to: stack, label: "Attention accent", cases: AttentionAccent.allCases,
                get: { $0.attentionAccent }, set: { $0.attentionAccent = $1 }
            )
            addChoice(
                to: stack, label: "Focus accent", cases: FocusAccent.allCases,
                get: { $0.focusAccent }, set: { $0.focusAccent = $1 }
            )
            addToggle(
                to: stack, label: "Transparent titlebar",
                get: { $0.transparentTitlebar }, set: { $0.transparentTitlebar = $1 },
                help: "Retired downstream: reaches ghostty in neither direction. Present so an absent knob cannot be mistaken for a bug."
            )
        }

        /// The focused pane's lift.
        ///
        /// `ringSpread` and `shadowDropBlur` are sliders with a floor at zero
        /// rather than text fields, which is the reviewer's first handoff item:
        /// a negative spread or blur produces geometry `CGPath` and `NSShadow` will
        /// happily draw and nobody can read, and a range that cannot express the
        /// bad value beats a clamp that silently rewrites a typed one.
        private func buildLift(into stack: NSStackView) {
            stack.addArrangedSubview(makeHeader("Lift"))
            addToggle(
                to: stack, label: "Enabled",
                get: { $0.chrome.lift.enabled }, set: { $0.chrome.lift.enabled = $1 }
            )
            addSlider(
                to: stack, label: "Ring spread", range: 0 ... 6, step: 0.1,
                get: { $0.chrome.lift.ringSpread }, set: { $0.chrome.lift.ringSpread = $1 }
            )
            addSlider(
                to: stack, label: "Ring alpha", range: 0 ... 1, step: 0.01,
                get: { $0.chrome.lift.ringAlpha }, set: { $0.chrome.lift.ringAlpha = $1 }
            )
            addSlider(
                to: stack, label: "Inner highlight offset Y", range: -6 ... 6, step: 0.5,
                get: { $0.chrome.lift.innerHighlightOffsetY },
                set: { $0.chrome.lift.innerHighlightOffsetY = $1 },
                help: "A shadow inset, not a layout inset: it moves where the highlight is drawn inside the frame and reaches no cell metric."
            )
            addSlider(
                to: stack, label: "Inner highlight alpha", range: 0 ... 1, step: 0.01,
                get: { $0.chrome.lift.innerHighlightAlpha },
                set: { $0.chrome.lift.innerHighlightAlpha = $1 }
            )
            addSlider(
                to: stack, label: "Shadow drop offset Y", range: -40 ... 40, step: 1,
                get: { $0.chrome.lift.shadowDropOffsetY },
                set: { $0.chrome.lift.shadowDropOffsetY = $1 }
            )
            addSlider(
                to: stack, label: "Shadow drop blur", range: 0 ... 80, step: 1,
                get: { $0.chrome.lift.shadowDropBlur },
                set: { $0.chrome.lift.shadowDropBlur = $1 }
            )
            addSlider(
                to: stack, label: "Shadow drop alpha", range: 0 ... 1, step: 0.01,
                get: { $0.chrome.lift.shadowDropAlpha },
                set: { $0.chrome.lift.shadowDropAlpha = $1 }
            )
            addSlider(
                to: stack, label: "Duration (s)", range: 0 ... 1, step: 0.01,
                get: { $0.chrome.lift.duration }, set: { $0.chrome.lift.duration = $1 },
                help: "Judged by watching a focus move, not by looking at a still. Reduce Motion still wins downstream."
            )
        }

        private func buildRim(into stack: NSStackView) {
            stack.addArrangedSubview(makeHeader("Rim"))
            addToggle(
                to: stack, label: "Enabled",
                get: { $0.chrome.rim.enabled }, set: { $0.chrome.rim.enabled = $1 }
            )
            addSlider(
                to: stack, label: "Top alpha", range: 0 ... 1, step: 0.01,
                get: { $0.chrome.rim.topAlpha }, set: { $0.chrome.rim.topAlpha = $1 },
                help: "Applies to whichever appearance is live. The constant tables keep one value per appearance; this dial has one."
            )
        }

        /// The ink derivations.
        ///
        /// Each ink shows its ratio and its hex side by side and says which is
        /// which, because they are different kinds of thing and the difference is
        /// not visible from the values: **the ratio walks the repair chain and
        /// stays legible; the hex bypasses it and can go illegible.** The hex wins
        /// when both are set, and the label says so, so the owner knows which one
        /// he is holding when the two disagree.
        ///
        /// The hex field commits on end-of-editing rather than per keystroke, and
        /// a rejected hex is dropped rather than substituted: `ConfigurationCenter`
        /// parses with `RGB(hex:)` and leaves the field nil on failure, so a
        /// half-typed `#ff` leaves the ink on its fallback instead of flashing a
        /// colour nobody chose. Nothing here validates or substitutes; the panel
        /// hands the string over exactly as typed.
        private func buildInks(into stack: NSStackView) {
            stack.addArrangedSubview(makeHeader("Inks"))
            stack.addArrangedSubview(makeNote(
                "Ratio walks the repair chain and stays legible. Hex bypasses it and can go illegible. Hex wins when both are set."
            ))
            addSlider(
                to: stack, label: "Session header — min ratio", range: 1 ... 21, step: 0.1,
                get: { $0.chrome.inks.sessionHeaderMinimumRatio },
                set: { $0.chrome.inks.sessionHeaderMinimumRatio = $1 }
            )
            addHex(
                to: stack, label: "Session header — hex (bypasses repair)",
                get: { $0.chrome.inks.sessionHeaderHex },
                set: { $0.chrome.inks.sessionHeaderHex = $1 }
            )
            addSlider(
                to: stack, label: "Action row — min ratio", range: 1 ... 21, step: 0.1,
                get: { $0.chrome.inks.actionRowMinimumRatio },
                set: { $0.chrome.inks.actionRowMinimumRatio = $1 }
            )
            addHex(
                to: stack, label: "Action row — hex (bypasses repair)",
                get: { $0.chrome.inks.actionRowHex },
                set: { $0.chrome.inks.actionRowHex = $1 }
            )
            addSlider(
                to: stack, label: "Section header — min ratio", range: 1 ... 21, step: 0.1,
                get: { $0.chrome.inks.sectionHeaderMinimumRatio },
                set: { $0.chrome.inks.sectionHeaderMinimumRatio = $1 },
                help: "The one already graded against bright glass, so the one whose repair actually fires."
            )
            addHex(
                to: stack, label: "Busy dot — hex (no ratio: a shape, not text)",
                get: { $0.chrome.inks.busyDotHex },
                set: { $0.chrome.inks.busyDotHex = $1 }
            )
        }

        /// Which fill each glass surface draws with.
        ///
        /// The choices come from `Material.allCases` and never from a list written
        /// here, which is the reviewer's seventh handoff item: adding a fifth case
        /// is meant to break the build at `SurfaceFill.swift`'s exhaustive switch,
        /// and a hand-written list in this file would let the same addition reach a
        /// popup with no drawing-site mapping behind it and compile.
        private func buildMaterials(into stack: NSStackView) {
            stack.addArrangedSubview(makeHeader("Materials"))
            stack.addArrangedSubview(makeNote(
                "All four fills are dormant at HEAD. A set value re-activates a retired path; nil is today's untinted glass."
            ))
            addChoice(
                to: stack, label: "Footer", cases: DesignOverrides.Chrome.Material.allCases,
                get: { $0.chrome.surfaces.footer }, set: { $0.chrome.surfaces.footer = $1 },
                help: "Glass appearance of a set fill is judged by looking at the running app, not at a still."
            )
            addChoice(
                to: stack, label: "Sidebar", cases: DesignOverrides.Chrome.Material.allCases,
                get: { $0.chrome.surfaces.sidebar }, set: { $0.chrome.surfaces.sidebar = $1 }
            )
            addChoice(
                to: stack, label: "Palette", cases: DesignOverrides.Chrome.Material.allCases,
                get: { $0.chrome.surfaces.palette }, set: { $0.chrome.surfaces.palette = $1 }
            )
            addChoice(
                to: stack, label: "Popover", cases: DesignOverrides.Chrome.Material.allCases,
                get: { $0.chrome.surfaces.popover }, set: { $0.chrome.surfaces.popover = $1 }
            )
            addChoice(
                to: stack, label: "Titlebar", cases: DesignOverrides.Chrome.Material.allCases,
                get: { $0.chrome.surfaces.titlebar }, set: { $0.chrome.surfaces.titlebar = $1 }
            )
        }

        /// The two chrome extras that belong to neither the lift, the rim, the inks
        /// nor the materials: the footer bar's lift off the terminal background,
        /// and the floor under the sidebar's wash.
        private func buildWindow(into stack: NSStackView) {
            stack.addArrangedSubview(makeHeader("Window"))
            addSlider(
                to: stack, label: "Bar lift (moves backdrop AND its ink)", range: 0 ... 1, step: 0.01,
                get: { $0.chrome.barLift }, set: { $0.chrome.barLift = $1 },
                help: "One slider, two things: `barBackground` is the backdrop the repair chain grades footer text on, so lifting the bar moves the text with it. That is the effect working."
            )
            addSlider(
                to: stack, label: "Sidebar wash floor (raises only)", range: 0 ... 1, step: 0.01,
                get: { $0.chrome.sidebarWashFloor }, set: { $0.chrome.sidebarWashFloor = $1 },
                help: "A floor, applied as max(opacity, floor). Setting it below the live background opacity does nothing; it cannot thin the wash."
            )
        }

        // MARK: - Row builders

        /// A labelled slider with a nil checkbox beside it.
        ///
        /// **Every row carries its own "set" checkbox**, unchecked meaning nil,
        /// because nil is the committed value and there is no slider position that
        /// can mean "not overriding". A slider alone would make the panel's mere
        /// existence pin every knob to whatever position it opened at, which is the
        /// exact failure ``BaiaSettings/DesignOverrides``' doc comment describes a
        /// non-optional field causing.
        ///
        /// Unchecking writes nil back and the knob returns to the committed value
        /// immediately, so a single row can be undone without Reset clearing the
        /// other thirty.
        ///
        /// **The checkbox reports the override; it does not gate the slider.**
        /// Dragging an unchecked row's slider writes the value *and* checks the
        /// box, rather than being ignored until the box is ticked. A drag is an
        /// unambiguous statement of intent, and a slider that moved under the
        /// pointer while nothing happened on screen would read as a broken panel
        /// long before anyone found the checkbox that explained it. So the box is
        /// an indicator plus a one-click way back to nil, and the only path that
        /// *sets* nil is unticking it or Reset.
        private func addSlider(
            to stack: NSStackView,
            label: String,
            range: ClosedRange<Double>,
            step: Double,
            get: @escaping (DesignOverrides) -> Double?,
            set: @escaping (inout DesignOverrides, Double?) -> Void,
            help: String? = nil
        ) {
            let toggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            let slider = NSSlider(value: range.lowerBound, minValue: range.lowerBound,
                                  maxValue: range.upperBound, target: nil, action: nil)
            slider.isContinuous = true
            let readout = NSTextField(labelWithString: "—")
            readout.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            readout.alignment = .right

            // Quantized in the handler rather than through `NSSlider.numberOfTickMarks`,
            // for the reason `SettingsView` records: ticks draw a dot per step and
            // a hundred dots under a slider is unreadable. What was ever wanted was
            // the rounding.
            let commitValue = { [weak self] in
                guard let self else { return }
                let raw = slider.doubleValue
                let quantized = (raw / step).rounded() * step
                set(&overrides, quantized)
                readout.stringValue = Self.format(quantized)
                toggle.state = .on
                commit()
            }
            let action = ActionTrampoline { commitValue() }
            slider.target = action
            slider.action = ActionTrampoline.fire
            keepAlive.append(action)

            let toggleAction = ActionTrampoline { [weak self] in
                guard let self else { return }
                if toggle.state == .on {
                    commitValue()
                } else {
                    set(&overrides, nil)
                    readout.stringValue = "—"
                    commit()
                }
            }
            toggle.target = toggleAction
            toggle.action = ActionTrampoline.fire
            keepAlive.append(toggleAction)

            refreshers.append { [weak self] in
                guard let self else { return }
                if let value = get(overrides) {
                    toggle.state = .on
                    slider.doubleValue = value
                    readout.stringValue = Self.format(value)
                } else {
                    toggle.state = .off
                    readout.stringValue = "—"
                }
            }

            stack.addArrangedSubview(makeRow(label: label, help: help,
                                             controls: [toggle, slider, readout],
                                             stretching: slider, readout: readout))
        }

        /// A tri-state row: nil, false, true.
        ///
        /// A segmented control rather than a checkbox, because a `Bool?` has three
        /// states and `NSButton`'s `.mixed` state means "partially on" to a reader
        /// rather than "not overriding". Three labelled segments say which is which.
        private func addToggle(
            to stack: NSStackView,
            label: String,
            get: @escaping (DesignOverrides) -> Bool?,
            set: @escaping (inout DesignOverrides, Bool?) -> Void,
            help: String? = nil
        ) {
            let segmented = NSSegmentedControl(labels: ["—", "Off", "On"],
                                               trackingMode: .selectOne,
                                               target: nil, action: nil)
            let action = ActionTrampoline { [weak self] in
                guard let self else { return }
                switch segmented.selectedSegment {
                case 1: set(&overrides, false)
                case 2: set(&overrides, true)
                default: set(&overrides, nil)
                }
                commit()
            }
            segmented.target = action
            segmented.action = ActionTrampoline.fire
            keepAlive.append(action)

            refreshers.append { [weak self] in
                guard let self else { return }
                switch get(overrides) {
                case .some(false): segmented.selectedSegment = 1
                case .some(true): segmented.selectedSegment = 2
                case nil: segmented.selectedSegment = 0
                }
            }

            stack.addArrangedSubview(makeRow(label: label, help: help,
                                             controls: [segmented], stretching: nil, readout: nil))
        }

        /// A popup over an enum's `allCases`, with a leading nil row.
        ///
        /// Generic over `RawRepresentable` so the four settings enums and
        /// `Material` all reach it, and so the cases always come from the type
        /// rather than from a list written beside it. See ``buildMaterials(into:)``.
        private func addChoice<Value: RawRepresentable & Equatable>(
            to stack: NSStackView,
            label: String,
            cases: [Value],
            get: @escaping (DesignOverrides) -> Value?,
            set: @escaping (inout DesignOverrides, Value?) -> Void,
            help: String? = nil
        ) where Value.RawValue == String {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItem(withTitle: "— (committed)")
            for value in cases { popup.addItem(withTitle: value.rawValue) }

            let action = ActionTrampoline { [weak self] in
                guard let self else { return }
                let index = popup.indexOfSelectedItem
                set(&overrides, index <= 0 ? nil : cases[index - 1])
                commit()
            }
            popup.target = action
            popup.action = ActionTrampoline.fire
            keepAlive.append(action)

            refreshers.append { [weak self] in
                guard let self else { return }
                if let value = get(overrides), let index = cases.firstIndex(of: value) {
                    popup.selectItem(at: index + 1)
                } else {
                    popup.selectItem(at: 0)
                }
            }

            stack.addArrangedSubview(makeRow(label: label, help: help,
                                             controls: [popup], stretching: popup, readout: nil))
        }

        /// A `#RRGGBB` text field.
        ///
        /// **No validation and no substitution here, on purpose.** The parse lives
        /// in `ConfigurationCenter.paneThemeAdjustments`, where `RGB(hex:)` answers
        /// nil and the ink keeps its fallback. A panel that repaired a rejected hex
        /// into some nearby colour would make a typo look like a choice, and one
        /// that refused to store it would make the field fight the typist mid-word.
        /// An empty string is the only string this treats specially, and it means
        /// nil rather than "the colour black".
        ///
        /// Commits on end-of-editing rather than on every keystroke: the field is
        /// where a half-typed value exists by definition, and `#ff` is a value the
        /// parser rejects on the way to `#ff8800` being one it accepts.
        private func addHex(
            to stack: NSStackView,
            label: String,
            get: @escaping (DesignOverrides) -> String?,
            set: @escaping (inout DesignOverrides, String?) -> Void
        ) {
            let field = HexField(string: "")
            field.placeholderString = "#RRGGBB"
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

            let action = ActionTrampoline { [weak self] in
                guard let self else { return }
                let text = field.stringValue.trimmingCharacters(in: .whitespaces)
                set(&overrides, text.isEmpty ? nil : text)
                commit()
                // A fast path, not the guarantee. `DesignPanel.resignKey()` and
                // `orderOut(_:)` are what actually hold the flag down, because
                // Escape and closing the panel mid-edit both end the session
                // without firing this action at all. See ``DesignPanel``.
                self.panel.wantsKey = false
            }
            // `action` on an `NSTextField` fires on Return and on focus loss, which
            // is exactly end-of-editing. `delegate`/`controlTextDidChange` would
            // fire per keystroke, which is the half-typed-hex case above.
            field.target = action
            field.action = ActionTrampoline.fire
            keepAlive.append(action)

            refreshers.append { [weak self] in
                guard let self else { return }
                field.stringValue = get(overrides) ?? ""
            }

            stack.addArrangedSubview(makeRow(
                label: label, help: "Click to type. Only this field takes key; the panel refuses it everywhere else.",
                controls: [field], stretching: field, readout: nil
            ))
        }

        /// Holds the action trampolines alive.
        ///
        /// `NSControl.target` is `weak`, so a trampoline created inside a row
        /// builder and referenced only by the control would deallocate before the
        /// first click and the control would silently do nothing. This array is the
        /// strong reference; nothing ever removes from it, which is correct because
        /// nothing ever removes a row.
        private var keepAlive: [ActionTrampoline] = []

        // MARK: - Row chrome

        /// One row: a caption over its controls, at a fixed column width.
        ///
        /// The width is pinned rather than left to the enclosing stack, because the
        /// stack is inside an `NSScrollView` whose document view has no width of
        /// its own until something gives it one, and an unpinned row in that
        /// position lays out at its intrinsic size and leaves every slider the
        /// width of its knob.
        ///
        /// `help` becomes a tooltip on the caption and on every control in the row,
        /// so the caveats that could not fit in a label (what `barLift` moves, that
        /// `sidebarWashFloor` only raises, that `innerHighlightOffsetY` is a shadow
        /// inset) are reachable from whatever the pointer happens to be over.
        private func makeRow(
            label: String,
            help: String?,
            controls: [NSView],
            stretching: NSView?,
            readout: NSTextField?
        ) -> NSView {
            let title = NSTextField(labelWithString: label)
            title.font = .systemFont(ofSize: 11)
            title.lineBreakMode = .byTruncatingTail
            title.toolTip = help

            let row = NSStackView(views: controls)
            row.orientation = .horizontal
            row.spacing = 6
            row.distribution = .fill
            // The stretching control absorbs the leftover width; everything beside
            // it (a checkbox, a fixed-width readout) keeps its intrinsic size.
            stretching?.setContentHuggingPriority(.defaultLow, for: .horizontal)
            stretching?.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            readout?.widthAnchor.constraint(equalToConstant: 46).isActive = true
            for control in controls { control.toolTip = help }

            let column = NSStackView(views: [title, row])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 2
            column.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            return column
        }

        private func makeHeader(_ text: String) -> NSView {
            let label = NSTextField(labelWithString: text.uppercased())
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }

        private func makeNote(_ text: String) -> NSView {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 10)
            label.textColor = .tertiaryLabelColor
            label.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
            return label
        }

        private static func format(_ value: Double) -> String {
            String(format: value.magnitude < 10 ? "%.2f" : "%.1f", value)
        }
    }

    /// The one control in the panel that needs the keyboard, and the one place
    /// ``DesignPanel/wantsKey`` is raised.
    ///
    /// The flag has to go up in `mouseDown` rather than in `becomeFirstResponder`,
    /// because AppKit asks the *window* whether it can become key while dispatching
    /// the click and before any responder has moved. Raising it later would be
    /// raising it after the answer that mattered was already no, and the field
    /// would stay uneditable while the flag sat true — the worst of both.
    ///
    /// Lowering happens on end-of-editing, in the controller's action handler,
    /// rather than here: `mouseDown` has no matching "done" event, and the action
    /// fires on both Return and focus loss, which is exactly the end of the session
    /// this raised the flag for.
    @MainActor
    final class HexField: NSTextField {
        override func mouseDown(with event: NSEvent) {
            (window as? DesignPanel)?.wantsKey = true
            // Asked for explicitly, because the panel was not key a moment ago and
            // AppKit will not promote it on its own now that the refusal has
            // lifted. This is the one `makeKey` in the panel and it is reached
            // only from a click into this field.
            window?.makeKey()
            super.mouseDown(with: event)
        }
    }

    /// A target object for an `NSControl`, wrapping a closure.
    ///
    /// AppKit's target/action predates blocks and `NSControl.target` is weak, so a
    /// panel with thirty-one rows otherwise needs an `@objc` method or a stored
    /// property per control. This is one class and one selector; ``keepAlive`` on
    /// the controller is what stops the weak target from dropping.
    @MainActor
    final class ActionTrampoline: NSObject {
        static let fire = #selector(ActionTrampoline.perform(_:))

        private let body: () -> Void

        init(_ body: @escaping () -> Void) {
            self.body = body
        }

        @objc func perform(_: Any?) { body() }
    }

#endif
