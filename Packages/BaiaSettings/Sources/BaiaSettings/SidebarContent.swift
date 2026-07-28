import Foundation

/// What the sidebar opens showing, or that there is no sidebar.
///
/// One region rather than one key per surface. The first draft gave the git panel
/// and the file tree a housing each, `off | sidebar | panel`, so that both could be
/// built and compared running. They were, on 2026-07-27, and the comparison
/// answered two things at once: the sidebar reads as the app's own icon, the
/// compartment planks make, and a window carrying both a sidebar and a floating
/// panel has one region too many. So the floating housing is retired for these two
/// surfaces, and this key names which content the single region starts on.
///
/// The floating housing itself is not retired: the command palette and the find
/// panel keep it. Those are transient, answering a question and leaving. These two
/// are consulted while work continues beside them, which is a different thing.
///
/// A starting state and not a restriction. Both contents stay reachable once the
/// sidebar is open, and switching between them changes no pane's width, so it costs
/// no reflow at all. The one reflow is the sidebar's first appearance.
public enum SidebarContent: String, Sendable, Equatable, CaseIterable {
    /// No sidebar. Not built, not shown, costing nothing, and the default, so a
    /// config written before this key existed launches into exactly what it
    /// launched into before.
    case off

    /// The git panel: which files are dirty, staged, untracked or conflicted.
    ///
    /// What the footer cannot say. The footer reports `*3 ?1` on one line that must
    /// not wrap, and this names the three and the one. Neither replaces the other,
    /// which is why the footer stands nothing down when the sidebar is open.
    case changes

    /// The file tree.
    ///
    /// The dangerous one, and the reason the sidebar must refuse first responder. A
    /// tree is a list you click, `AppTerminalView.performKeyEquivalent` opens with
    /// `guard window?.firstResponder === self`, and that is the *window's* first
    /// responder: a row that takes it would disable every ghostty binding in every
    /// pane of the window, not just one. Clicks are handled in `mouseDown` without
    /// taking focus, the way `PaneStatusBarView` already does.
    case files

    /// Both, changes above the tree.
    ///
    /// Not a compromise between the other two. The surfaces are not symmetrical: a
    /// changes list is a handful of rows and a file tree is a whole repository, so
    /// the short glanceable one sits on top with a cap on its height and the long
    /// browsable one takes the rest of the column. They also answer questions that
    /// arrive together, what did I change and where does it live, and switching
    /// between them costs a gesture every time that pair is asked.
    ///
    /// Costs no width, so it costs no reflow. Stacking happens inside a column whose
    /// width never moves.
    case both
}
