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
/// panel keep it. Those are transient, answering a question and leaving. The tree
/// is consulted while work continues beside it, which is a different thing.
///
/// A starting state and not a restriction. The sidebar stays openable and closable
/// once the app is running, and opening it changes no pane's height, so the one
/// reflow it ever costs is its first appearance taking width.
///
/// **Two cases since 2026-08-12, and four before it.** `changes` named a git panel
/// listing the dirty, staged, untracked and conflicted files, and `both` stacked
/// that panel above the tree. The owner's ruling that day removed the section: the
/// capsule's changes card already lists the changed files with their status letters
/// and hands each one to a diff split, so the column was a second copy of the same
/// list in the same window. Both cases went with it. A config still naming either is
/// rejected by ``SettingsDecoder`` the way it rejects any unknown spelling, which
/// leaves the sidebar off rather than guessing at a replacement.
public enum SidebarContent: String, Sendable, Equatable, CaseIterable {
    /// No sidebar. Not built, not shown, costing nothing, and the default, so a
    /// config written before this key existed launches into exactly what it
    /// launched into before.
    case off

    /// The file tree.
    ///
    /// The dangerous one, and the reason the sidebar must refuse first responder. A
    /// tree is a list you click, `AppTerminalView.performKeyEquivalent` opens with
    /// `guard window?.firstResponder === self`, and that is the *window's* first
    /// responder: a row that took it would disable every ghostty binding in every
    /// pane of the window, not just one. Clicks are handled in `mouseDown` without
    /// taking focus, the way the pane's own chrome does.
    case files
}
