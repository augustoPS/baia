import Foundation

/// Whether each command is available, given what the app can currently do.
public enum MenuValidation {
    /// An exhaustive switch over ``MenuCommand`` with no `default` clause.
    ///
    /// The missing `default` is the entire point. Adding a command is a compile
    /// error here until its rule is written, so a new item cannot ship enabled
    /// by accident the way a `default: return true` would let it. AppKit's own
    /// behaviour is that unvalidated items are enabled, which is what
    /// `AppDelegate.validateMenuItem` returns today for everything except Clear
    /// Pin, and it is why an item wired to a command the app cannot perform
    /// looks live and beeps.
    public static func state(
        for command: MenuCommand,
        given availability: MenuAvailability
    ) -> MenuItemState {
        switch command {
        // Nothing the app can be doing makes these wrong. Quit in particular
        // stays enabled with no window at all: baia shipped without a ⌘Q once and
        // closing the window was the only way to leave the app.
        case .about, .hide, .hideOthers, .showAll, .quit,
             .newWindow, .newTab, .openConfiguration,
             .reloadProjectList, .mergeAllWindows, .bringAllToFront, .copyDiagnostics:
            MenuItemState(isEnabled: true, isChecked: nil)

        // Always available, and checkable, so hiding the status bars is
        // discoverable from the menu rather than only by pressing the key again.
        case .toggleStatusBars:
            MenuItemState(isEnabled: true, isChecked: availability.statusBarsVisible)

        // The only other checkable item. Zooming needs something to zoom away
        // from, so a single pane disables it, and the check is what tells the
        // user which state ⇧⌘↩ will leave them in.
        case .zoomPane:
            MenuItemState(isEnabled: availability.paneCount > 1, isChecked: availability.isZoomed)

        // Two panes minimum. Close Pane is deliberately in here rather than in
        // the group below: with one pane there is nothing to collapse into, and
        // enabling it would make ⌘W and ⌥⌘W both close the tab, which is how the
        // ⌘W assignment stops being the one the owner's muscle memory expects.
        case .closePane, .selectNextPane, .selectPreviousPane,
             .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
             .growPaneLeft, .growPaneRight, .growPaneUp, .growPaneDown, .equalizePanes:
            MenuItemState(isEnabled: availability.paneCount > 1, isChecked: nil)

        // One pane is enough. The Edit items are validated here even though
        // ghostty owns their keys, because the items are still clickable and a
        // click with no pane travels a responder chain holding no terminal, which
        // AppKit answers with a beep.
        case .copy, .paste, .pasteSelection, .selectAll, .splitRight, .splitDown, .setProjectDirectory:
            MenuItemState(isEnabled: availability.paneCount > 0, isChecked: nil)

        // A window has to exist. Keyed on the tab count rather than a separate
        // `hasWindow` flag: a window always holds at least one tab, so the two
        // would be one fact stored twice and free to disagree.
        case .closeTab, .closeWindow, .minimize, .zoomWindow, .enterFullScreen:
            MenuItemState(isEnabled: availability.tabCount > 0, isChecked: nil)

        // Cycling to the next tab of one is a no-op that still consumes the key.
        case .showPreviousTab, .showNextTab:
            MenuItemState(isEnabled: availability.tabCount > 1, isChecked: nil)

        // The rule that already exists in AppDelegate.validateMenuItem: clearing
        // a pin that is not set is meaningless, and the item was the reason that
        // method exists at all.
        case .clearProjectDirectoryPin:
            MenuItemState(isEnabled: availability.isPinned, isChecked: nil)

        // A pane has no anchor until its first working directory arrives, which
        // is up to one poll interval after the pane appears.
        case .revealAnchor, .copyAnchorPath:
            MenuItemState(isEnabled: availability.hasAnchor, isChecked: nil)

        // Both conditions, not just the kind. A plain anchor is what a pane gets
        // outside any repository and it has no branch, no ahead or behind count,
        // and nothing to refresh.
        case .refreshGitStatus:
            MenuItemState(
                isEnabled: availability.hasAnchor && availability.anchorIsRepository,
                isChecked: nil
            )

        // Enabled whenever there is a pane to search. An empty result is a real
        // answer and the panel says so, which is more useful than an item that
        // greys out for reasons the owner cannot see. Deliberately not keyed on
        // whether the pane has produced any output yet: that is a fact only a
        // live surface knows, and asking for it here would make validation, which
        // AppKit runs on every menu open and every key equivalent, read the
        // scrollback.
        case .findInPane:
            MenuItemState(isEnabled: availability.paneCount > 0, isChecked: nil)

        // An empty palette reads as a workspace holding no projects, which is
        // worse than a disabled item that says the list is not loaded yet.
        case .commandPalette:
            MenuItemState(isEnabled: availability.paletteAvailable, isChecked: nil)
        }
    }
}
