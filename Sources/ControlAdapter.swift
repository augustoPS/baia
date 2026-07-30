import AppKit
import PaneChrome
import PaneControl
import WorkspaceLayout

/// The workspace end of the control channel.
///
/// **No policy lives here, and that is the whole shape of the type.** By the time
/// a method below runs, `PaneGraph.authorize` has already said yes, the settings
/// gate has already run, and the pane named is one the caller is allowed to
/// touch. What is left is translation: a `ControlPaneID` into a window, a
/// `ControlVerb` into a `Workspace` mutation, and a `Bool` back out into the frame
/// the caller reads. Every refusal below is a refusal the *workspace* made, not
/// one this type decided.
///
/// The two exceptions look like policy and are not. `zoom` refuses an unfocused
/// caller and `focus` refuses a background window, and both are facts about what
/// the layout can express rather than about who is allowed to ask: `Workspace`'s
/// invariant is that a zoomed pane is its tab's focused pane, and raising a window
/// is something AppKit does that the workspace has no way to undo. Each is
/// recorded on the arm that answers it.
@MainActor
final class ControlAdapter: ControlWorkspaceBridge {
    /// Every workspace window baia owns, asked for rather than held.
    ///
    /// A closure over the delegate's own array, because windows open and close
    /// and a copy taken at init would be stale by the first split. The delegate
    /// keeps the array unordered on purpose, so the ordering this type needs is
    /// derived below from `tabGroup`, which is where tab order actually lives.
    private let windows: () -> [WorkspaceWindowController]

    /// Where the keyboard is, which is the only question `focus` has to ask about
    /// something outside the workspace.
    private let keyWindow: () -> NSWindow?

    init(
        windows: @escaping () -> [WorkspaceWindowController],
        keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow }
    ) {
        self.windows = windows
        self.keyWindow = keyWindow
    }

    // MARK: The pane-to-window index

    /// Where one pane sits, and everything needed to act on it.
    private struct Placement {
        /// One-based, for a human reading `baia list`.
        let window: Int
        let tab: Int
        let controller: WorkspaceWindowController
        let pane: TerminalPaneController

        var tree: PaneTreeController { controller.tree }
    }

    /// The pane-to-window index, rebuilt per request rather than maintained.
    ///
    /// A cached index would be a second truth about which window holds a pane,
    /// and it would go wrong in exactly the cases that matter: a tab dragged out,
    /// two windows merged, a pane closed by its own shell exiting. None of those
    /// route through this type, and a stale entry here would send a mutation to a
    /// window that no longer holds the pane. The walk is over a handful of windows
    /// and a handful of panes, once per request, against a socket a person is
    /// typing at.
    ///
    /// Numbering follows `tabGroup`, the same source `AppDelegate.orderedWindows()`
    /// reads, because that is the only place tab order exists. A detached window
    /// is a group of one.
    private func placements() -> [PaneID: Placement] {
        let controllers = windows()
        var placements: [PaneID: Placement] = [:]
        var seen: Set<ObjectIdentifier> = []
        var windowNumber = 0

        for controller in controllers {
            guard !seen.contains(ObjectIdentifier(controller)) else { continue }
            windowNumber += 1
            var tabNumber = 0
            let group = controller.window.tabGroup?.windows ?? [controller.window]
            for window in group {
                guard let match = controllers.first(where: { $0.window === window }),
                      seen.insert(ObjectIdentifier(match)).inserted
                else { continue }
                tabNumber += 1
                for pane in match.tree.allPanes {
                    placements[pane.paneID] = Placement(
                        window: windowNumber,
                        tab: tabNumber,
                        controller: match,
                        pane: pane
                    )
                }
            }
        }
        return placements
    }

    private func placement(of pane: ControlPaneID) -> Placement? {
        placements()[pane.layout]
    }

    // MARK: Describing a pane

    /// What `whoami`, `list`, and `peers` say about one pane.
    ///
    /// **Display ids and human-readable strings, and no path from here to the
    /// registry.** This method is handed a resolved `ControlPaneID` and has no way
    /// to ask about a secret: `PaneControlChannel` exposes no lookup, `PaneSecret`
    /// is not `Codable`, and `TerminalPaneController.controlSecret` is never read
    /// after the pane is registered. A record cannot carry a capability even by
    /// accident.
    ///
    /// No filtering. The server asks about exactly the panes the caller may see,
    /// each already run past `PaneGraph.authorize` twice, so a second scope check
    /// here would be half the scope rule sitting somewhere with no test on it.
    ///
    /// `channels` and `peers` are left empty and filled in by the server, which
    /// owns the graph. That is why this type holds no reference to it.
    func record(for pane: ControlPaneID) -> PaneRecord? {
        guard let placed = placement(of: pane) else { return nil }
        let controller = placed.pane
        let anchor = controller.anchorTracker.anchor

        return PaneRecord(
            pane: pane.description,
            window: placed.window,
            tab: placed.tab,
            workingDirectory: controller.anchorTracker.workingDirectory?
                .path(percentEncoded: false),
            anchor: anchor?.url.path(percentEncoded: false),
            branch: controller.gitStatus.git?.head,
            activity: controller.activityLabel,
            attention: Self.name(of: controller.attentionState),
            createdBy: controller.createdBy?.rawValue.uuidString
        )
    }

    /// The chrome's three attention levels, spelled for a reader.
    ///
    /// Nil for `none`, so a pane that is not asking prints no `attention` line at
    /// all rather than a line saying nothing happened. No `default:`: a fourth
    /// level has to decide what it is called here before this compiles.
    private static func name(of attention: PaneStatus.Attention) -> String? {
        switch attention {
        case .none: nil
        case .asking: "asking"
        case .acknowledged: "acknowledged"
        }
    }

    // MARK: Moving a pane

    /// Applies one authorised layout verb and answers with the caller's frame.
    ///
    /// No `default:`, matching `ControlVerb.scope` and the server's own router: a
    /// verb added without a route has to fail to compile here rather than fall
    /// through to whatever the fallback happened to answer.
    func applyLayout(
        _ verb: ControlVerb,
        to pane: ControlPaneID,
        args: ControlArgs
    ) -> ControlResponse {
        guard let placed = placement(of: pane) else {
            // The graph still holds a registration for a pane no window has. It is
            // the caller's own pane, since every v1 layout verb is self-relative,
            // so this is not a probe and there is nothing to withhold.
            return .failure(
                .notFound,
                "baia no longer has that pane. Its window may have closed while this request "
                    + "was in flight."
            )
        }

        switch verb {
        case .split:
            return split(placed, args: args)
        case .close:
            return close(placed, pane: pane)
        case .focus:
            return focus(placed)
        case .zoom:
            return zoom(placed, args: args)
        case .resize:
            return resize(placed, args: args)
        case .equalize:
            return equalize(placed)
        case .cwd:
            return report(cwd: args.cwd, on: placed)

        case .whoami, .list, .peers, .publish, .connect, .send, .recv, .subscribe, .revoke, .run:
            // Unreachable: the server routes these to the graph and never here.
            // The arm exists because the switch has no `default:` and never will.
            return .failure(
                .internal,
                "\(verb.rawValue) is answered by the graph and never by the workspace"
            )
        }
    }

    /// Hands the pane a working directory it says it moved to.
    ///
    /// Straight through to the tracker's OSC 7 entry point, which has existed
    /// unused because nothing emits OSC 7: the bundled libghostty ships no
    /// shell-integration resources. This is the caller taking that job.
    ///
    /// Advisory, and it does not pin. The one-second poll of the foreground
    /// process's cwd keeps running, and a later read that disagrees wins, because
    /// then the pane genuinely moved and this announcement is stale.
    ///
    /// The path is not checked for existence. A directory that vanishes between
    /// the announcement and the read is the same race the poll already lives with,
    /// and `AnchorResolver` already drops an anchor it cannot resolve.
    private func report(cwd: String?, on placed: Placement) -> ControlResponse {
        guard let cwd, !cwd.isEmpty else {
            return .failure(.refused, "cwd needs a path")
        }
        placed.pane.anchorTracker.reportWorkingDirectory(
            (cwd as NSString).expandingTildeInPath
        )
        return .success()
    }

    private func split(_ placed: Placement, args: ControlArgs) -> ControlResponse {
        // `horizontal` is side by side, matching `SplitAxis` and `⌘D`, which is
        // what `baia split --right` asks for. The CLI already defaults it, and the
        // same default is applied here rather than trusted from the frame.
        let axis: SplitAxis = args.axis == .vertical ? .vertical : .horizontal

        guard let new = placed.tree.split(
            pane: placed.pane.paneID,
            axis: axis,
            workingDirectory: args.cwd,
            createdBy: placed.pane.paneID
        ) else {
            return .failure(
                .refused,
                "baia refused that split. Another pane has this tab zoomed, and the new pane "
                    + "would be invisible until a zoom this pane does not own was cleared."
            )
        }
        return .success(ControlResult(pane: new.rawValue.uuidString))
    }

    /// **Writes before it kills.**
    ///
    /// The pane being closed is the pane whose shell is waiting on this response,
    /// so the refusal is decided now, the success frame is returned now, and the
    /// close itself is scheduled for the next turn of the main loop. The server
    /// hands the frame to the transport synchronously on the way out of this call,
    /// which is inside the current turn, so the write is queued before the shell
    /// can die. A client that loses that race anyway sees EOF and treats it as
    /// success, which is what the CLI does.
    ///
    /// Refused for the window's last pane, and the window is not closed. ⌘W closes
    /// it, because an owner asking to close the last pane means closing the window;
    /// a channel that did the same would let one compromised pane take a window
    /// down, and at the last window take the app with it.
    private func close(_ placed: Placement, pane: ControlPaneID) -> ControlResponse {
        guard placed.tree.canClose(pane: placed.pane.paneID) else {
            return .failure(
                .refused,
                "this is the window's last pane. baia keeps a window showing something, so "
                    + "closing it is closing the window, which the channel does not do."
            )
        }

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                // The placement is resolved again rather than captured. A turn of
                // the main loop is enough for the window holding this pane to have
                // gone, and a captured controller would then be closing a pane out
                // of a tree nothing else can reach.
                guard let placed = self?.placement(of: pane) else { return }
                placed.tree.close(pane: placed.pane.paneID)
            }
        }
        return .success()
    }

    /// Three cases, and only the third refuses.
    ///
    /// A caller in the key window goes straight through. A caller in a **non-focused
    /// tab of the key window** may select that tab, because selecting a tab raises
    /// no window: the group is already in front and only which of its tabs shows
    /// changes. A caller in a **background window** is refused and that window is
    /// never raised, because a channel that could pull windows forward can steal
    /// focus from the owner's actual work, which is the "effects that look
    /// owner-initiated" harm the whole design bounds.
    private func focus(_ placed: Placement) -> ControlResponse {
        let window = placed.controller.window

        if window.isKeyWindow {
            _ = placed.tree.focus(pane: placed.pane.paneID)
            return .success()
        }

        if let key = keyWindow(),
           let group = key.tabGroup,
           group.windows.contains(window) {
            group.selectedWindow = window
            _ = placed.tree.focus(pane: placed.pane.paneID)
            return .success()
        }

        return .failure(
            .refused,
            "that pane is in a background window, and baia does not raise a window for the "
                + "channel. Bring the window forward yourself and ask again."
        )
    }

    private func zoom(_ placed: Placement, args: ControlArgs) -> ControlResponse {
        guard let state = placed.tree.zoom(pane: placed.pane.paneID, to: args.on) else {
            return .failure(
                .refused,
                "zoom follows focus; the calling pane is not focused. Run `baia focus && baia "
                    + "zoom` if you meant to take the window."
            )
        }
        return .success(ControlResult(zoomed: state))
    }

    private func resize(_ placed: Placement, args: ControlArgs) -> ControlResponse {
        guard let direction = args.direction else {
            return .failure(.badFrame, "resize needs a direction: left, right, up, or down")
        }

        // Clamped here rather than trusted from the frame, and the bound is the
        // same one a divider has: past half the split there is no arrangement
        // left to express, and zero or less is a request to move nothing.
        let requested = args.by ?? PaneTree.keyboardResizeStep
        let delta = min(max(requested, PaneTree.keyboardResizeStep), 0.5)

        guard placed.tree.resize(
            pane: placed.pane.paneID,
            direction: Self.direction(of: direction),
            by: delta
        ) else {
            return .failure(
                .refused,
                "there is no divider that way, it is already against its stop, or this tab is "
                    + "zoomed and shows no divider at all."
            )
        }
        return .success()
    }

    private func equalize(_ placed: Placement) -> ControlResponse {
        guard placed.tree.equalize(tabContaining: placed.pane.paneID) else {
            return .failure(
                .refused,
                "every divider in this tab is already even, or the tab is zoomed and shows no "
                    + "divider at all."
            )
        }
        return .success()
    }

    /// The wire's spelling of a direction onto the layout package's.
    ///
    /// Two enums for one idea because `PaneControl` imports Foundation and nothing
    /// else, and `FocusDirection` is deliberately not `Codable` over there: a
    /// direction is a keystroke and never session state. No `default:`, so a fifth
    /// direction has to be mapped rather than silently becoming `left`.
    private static func direction(of direction: ControlDirection) -> FocusDirection {
        switch direction {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        }
    }
}
