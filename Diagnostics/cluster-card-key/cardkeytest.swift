import AppKit
import BaiaSettings
import PaneChrome

// Does the cluster card's key discipline hold on a real window — key taken on
// show, returned on every dismissal path, and the capsule still clickable
// while the card holds it? One arm per path. See README.md.
//
// `ClusterCardController` is compiled verbatim: unlike `DesignPanel`, it
// shares no file with anything that reaches the app target, so the thing under
// test here is the shipped code and not a retype. The one retyped class is
// `PalettePanel` (two overrides, grep-guarded by `run.sh` against
// `Sources/CommandPaletteController.swift`), because that class *does* share a
// file with the palette controller and the whole app target behind it.

/// The shipped `PalettePanel`, retyped: a borderless panel that is still
/// allowed to take the keyboard, and never main.
///
/// `refusesKey` is the negative controls' handle. The five card arms are
/// asserting behaviour of verbatim-compiled code, so the honest way to damage
/// the system is at the stand-in: a panel that cannot become key is a card
/// mechanism whose entire key discipline is vacuous, and every arm asserts
/// "the card took key" as its precondition, so each control fails there rather
/// than passing on assertions that never engaged.
final class PalettePanel: NSPanel {
    nonisolated(unsafe) static var refusesKey = false

    override var canBecomeKey: Bool { !Self.refusesKey }

    override var canBecomeMain: Bool { false }
}

/// A card view keeping the shipped cards' Esc contract:
/// `ClusterPlaceCardView` and `ClusterChangesCardView` both answer
/// `cancelOperation(_:)` and a keyCode-53 `keyDown` with `onClose`, and the
/// pane wires `onClose = { clusterCards.dismiss() }`. The probe's card does
/// exactly that, so the esc arm exercises the same responder route a real ⎋
/// takes: panel first responder → the content view's own responder methods.
final class ProbeCardView: NSView {
    var onClose: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func cancelOperation(_: Any?) { onClose?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 0x35 {
            onClose?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// A stand-in for the capsule with the `acceptsFirstMouse` override *missing*:
/// `NSView`'s default answers false. The first-mouse control installs this in
/// the capsule's place and posts the identical click; a click that still
/// arrived would mean the mechanism never consulted the override and the arm
/// was proving nothing. Measured before this probe was written: a synthetic
/// `NSEvent` through `NSWindow.sendEvent` *or* `NSApplication.sendEvent`
/// delivers `mouseDown` regardless of `acceptsFirstMouse`, so the honest
/// mechanism is a real CGEvent through the window server — `lib/click.swift`'s
/// post, inlined — and this control is what proves the gate is live in this
/// harness.
final class NoOverrideView: NSView {
    var clicks = 0
    override func mouseDown(with _: NSEvent) { clicks += 1 }
    override var isFlipped: Bool { true }
}

// MARK: - Harness

let app = NSApplication.shared

var failures: [String] = []

func check(_ label: String, _ ok: Bool) {
    if ok {
        print("  ok    \(label)")
    } else {
        print("  FAIL  \(label)")
        failures.append(label)
    }
}

/// Pumps the app's own event queue, dequeuing through
/// `NSApplication.sendEvent` the way a running app does.
///
/// `nextEvent` rather than `RunLoop.run`, unlike `design-panel-key`'s
/// `settle`: that probe only waited on window-server *state* (key flags),
/// which the run loop delivers. Two arms here need real *events* delivered —
/// the posted CGEvent click, and whatever AppKit queues around key handoffs —
/// and a process that never dequeues its event queue never receives them.
func pump(_ seconds: TimeInterval = 0.35) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if let event = app.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            app.sendEvent(event)
        }
    }
}

func makeHost() -> NSWindow {
    let host = NSWindow(
        contentRect: NSRect(x: 300, y: 300, width: 480, height: 320),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    host.isReleasedWhenClosed = false
    // Above ordinary windows so the first-mouse arm's click point cannot be
    // covered by whatever the desktop happens to hold; verified again per
    // click with `NSWindow.windowNumber(at:)` before anything is posted.
    host.level = .popUpMenu
    return host
}

/// A host on screen and key, which is the state a card is summoned from: the
/// pane's window has the keyboard and the capsule was just clicked.
func keyHost() -> NSWindow {
    let host = makeHost()
    host.makeKeyAndOrderFront(nil)
    pump(0.25)
    return host
}

/// The capsule fixture, the same four segments `cluster-wires` renders.
let segments: [PaneClusterSegment] = [
    PaneClusterSegment(role: .place, text: "main"),
    PaneClusterSegment(role: .changes, text: "↑1*?3"),
    PaneClusterSegment(role: .agent, text: "working"),
    PaneClusterSegment(role: .attention, text: ""),
]

/// Where the card anchors: a segment rect in the host window's coordinate
/// space, the contract `show(content:anchoredTo:in:)` states.
func anchorRect(in host: NSWindow) -> NSRect {
    let content = host.contentView!
    return NSRect(
        x: content.bounds.maxX - 160, y: content.bounds.maxY - 26,
        width: 60, height: 20
    )
}

func makeCard(size: NSSize = NSSize(width: 220, height: 140)) -> ProbeCardView {
    ProbeCardView(frame: NSRect(origin: .zero, size: size))
}

// MARK: - Arms

/// Every arm's precondition: the card is up and its panel has the keyboard.
/// Asserted through `NSApp.keyWindow` and the content view's own window
/// rather than through the controller's flag alone, so "key" is what AppKit
/// says rather than two fields agreeing with each other.
func assertCardIsKey(_ controller: ClusterCardController, _ content: NSView, _ host: NSWindow, _ arm: String) {
    check("\(arm): card is showing", controller.isShowing)
    check("\(arm): panel is key", content.window != nil && content.window === NSApp.keyWindow)
    check("\(arm): host is not key", host.isKeyWindow == false)
}

/// show → panel is key, host is not.
func armShow() {
    print("show")
    let host = keyHost()
    check("show: host is key before", host.isKeyWindow)

    let controller = ClusterCardController()
    let content = makeCard()
    controller.show(content: content, anchoredTo: anchorRect(in: host), in: host)
    pump(0.25)

    assertCardIsKey(controller, content, host, "show")
    controller.dismiss()
    host.close()
    pump(0.1)
}

/// ⎋ in the card: a synthesized keyCode-53 keyDown sent to the panel, routed
/// to the content view (the panel's first responder, the direct grant `show`
/// makes) whose `onClose` calls `dismiss()` — the shipped cards' exact wiring.
func armEsc() {
    print("esc")
    let host = keyHost()
    let controller = ClusterCardController()
    let content = makeCard()
    var dismissed = 0
    content.onClose = { [weak controller] in controller?.dismiss() }
    controller.show(content: content, anchoredTo: anchorRect(in: host), in: host) { dismissed += 1 }
    pump(0.25)
    assertCardIsKey(controller, content, host, "esc")

    let panel = content.window!
    let esc = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: panel.windowNumber, context: nil,
        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false, keyCode: 0x35
    )!
    panel.sendEvent(esc)
    pump(0.25)

    check("esc: card is gone", controller.isShowing == false)
    check("esc: onDismiss fired once", dismissed == 1)
    check("esc: host is key again", host.isKeyWindow)
    host.close()
    pump(0.1)
}

/// Click-outside, modelled from this panel's side the way `design-panel-key`
/// models it: the host takes key while the card shows. The card must come down
/// through the resign observer, which is documented one turn late, so the run
/// loop is pumped before the assertion rather than the assertion made
/// synchronously.
func armClickOutside() {
    print("click-outside")
    let host = keyHost()
    let controller = ClusterCardController()
    let content = makeCard()
    var dismissed = 0
    controller.show(content: content, anchoredTo: anchorRect(in: host), in: host) { dismissed += 1 }
    pump(0.25)
    assertCardIsKey(controller, content, host, "click-outside")

    host.makeKey()
    pump(0.35)

    check("click-outside: card dismissed via the resign observer", controller.isShowing == false)
    check("click-outside: onDismiss fired once", dismissed == 1)
    check("click-outside: host is key", host.isKeyWindow)
    host.close()
    pump(0.1)
}

/// show, then show again with different content: the switch. The second card
/// must survive the first's queued resign delivery — the 63fd178 race, where
/// the internal dismiss's one-turn-late `didResignKey` tore the new card down
/// one turn after it opened. So the arm's load-bearing assertions come *after*
/// the pump, on a card that has lived through the turn the regression fired on.
func armSwitch() {
    print("switch")
    let host = keyHost()
    let controller = ClusterCardController()
    let first = makeCard()
    let second = makeCard(size: NSSize(width: 260, height: 100))
    var firstDismissed = 0
    var secondDismissed = 0

    controller.show(content: first, anchoredTo: anchorRect(in: host), in: host) { firstDismissed += 1 }
    pump(0.25)
    assertCardIsKey(controller, first, host, "switch(first)")

    controller.show(content: second, anchoredTo: anchorRect(in: host), in: host) { secondDismissed += 1 }
    check("switch: first card's onDismiss fired on the switch", firstDismissed == 1)

    pump(0.5)

    assertCardIsKey(controller, second, host, "switch(second, after the turn the race fired on)")
    check("switch: first card's view left the panel", first.window == nil)
    check("switch: first card's onDismiss fired exactly once", firstDismissed == 1)
    check("switch: second card's onDismiss has not fired", secondDismissed == 0)
    controller.dismiss()
    host.close()
    pump(0.1)
}

/// show, then `dismiss()` directly: the hadKey restore hands key back to the
/// host rather than to nothing.
func armDismiss() {
    print("dismiss")
    let host = keyHost()
    let controller = ClusterCardController()
    let content = makeCard()
    var dismissed = 0
    controller.show(content: content, anchoredTo: anchorRect(in: host), in: host) { dismissed += 1 }
    pump(0.25)
    assertCardIsKey(controller, content, host, "dismiss")

    controller.dismiss()
    pump(0.25)

    check("dismiss: card is gone", controller.isShowing == false)
    check("dismiss: onDismiss fired once", dismissed == 1)
    check("dismiss: host is key again (hadKey restore)", host.isKeyWindow)
    host.close()
    pump(0.1)
}

/// The question Task 5 deferred here: with the card up and its panel key, does
/// a click on the capsule in the non-key host still reach `onSegmentClick`?
/// That is `PaneClusterView.acceptsFirstMouse` earning its keep — without it
/// AppKit spends the first click on re-activation and delivers nothing.
///
/// A real CGEvent through the window server, because the synthetic routes are
/// dishonest here: measured while writing this probe, `NSWindow.sendEvent` and
/// `NSApplication.sendEvent` both deliver a synthesized `mouseDown` to the view
/// regardless of what `acceptsFirstMouse` answers — the first-mouse discard
/// happens upstream of anything a synthesized `NSEvent` can enter through. The
/// `broken` variant swaps in ``NoOverrideView`` and is what shows the gate
/// operates on this path: the identical click, undelivered.
func armFirstMouse(broken: Bool) {
    print("first-mouse\(broken ? " (no acceptsFirstMouse override)" : "")")

    guard CGPreflightPostEventAccess() else {
        check("first-mouse: this process may post CGEvents (grant Accessibility to the terminal running this)", false)
        return
    }

    let host = keyHost()
    let content = host.contentView!

    // The capsule pinned where the pane pins it: top-right, inset by the
    // shipped `PaneClusterMetrics.cornerInset` on both axes.
    let capsule = PaneClusterView(frame: .zero)
    capsule.segments = segments
    let size = capsule.intrinsicContentSize
    let inset = PaneClusterMetrics.cornerInset
    let frame = NSRect(
        x: content.bounds.maxX - size.width - inset,
        y: content.bounds.maxY - size.height - inset,
        width: size.width, height: size.height
    )
    var clickedRole: PaneClusterSegmentRole?
    var standIn: NoOverrideView?
    var clickTarget: NSView
    if broken {
        let view = NoOverrideView(frame: frame)
        standIn = view
        clickTarget = view
    } else {
        capsule.frame = frame
        capsule.onSegmentClick = { role, _ in clickedRole = role }
        clickTarget = capsule
    }
    content.addSubview(clickTarget)
    pump(0.2)

    // The card up, anchored below the place segment the way the pane anchors
    // it: hanging below the capsule, clear of the click point above it.
    let controller = ClusterCardController()
    let card = makeCard()
    let segmentInHost = clickTarget.convert(
        NSRect(x: 8, y: 0, width: 40, height: frame.height), to: nil
    )
    controller.show(content: card, anchoredTo: segmentInHost, in: host)
    pump(0.25)
    check("first-mouse: panel is key before the click", card.window === NSApp.keyWindow)
    check("first-mouse: host is not key before the click", host.isKeyWindow == false)

    // The place segment's centre — recomputed with the view's own font and
    // arithmetic, the way `cluster-wires` finds its pixels — in screen points,
    // then in CG's top-left coordinates.
    let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    let placeWidth = Double(NSAttributedString(
        string: "main", attributes: [.font: font]
    ).size().width)
    let inView = NSPoint(
        x: PaneClusterMetrics.horizontalInset + placeWidth / 2,
        y: frame.height / 2
    )
    let onScreen = host.convertPoint(toScreen: clickTarget.convert(inView, to: nil))

    // Refuse to click a point some other window covers: a CGEvent lands on
    // whatever is topmost, and this probe must never press someone else's
    // button.
    let atPoint = NSWindow.windowNumber(at: onScreen, belowWindowWithWindowNumber: 0)
    guard atPoint == host.windowNumber else {
        check("first-mouse: the click point is this probe's own window (found window \(atPoint))", false)
        controller.dismiss()
        host.close()
        return
    }

    // `lib/click.swift`'s post, inlined: real events through the HID tap,
    // because that is the one route the first-mouse gate sits on.
    let cg = CGPoint(x: onScreen.x, y: NSScreen.screens[0].frame.height - onScreen.y)
    let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: cg, mouseButton: .left)
    let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: cg, mouseButton: .left)
    down?.post(tap: .cghidEventTap)
    usleep(60_000)
    up?.post(tap: .cghidEventTap)
    pump(0.6)

    if broken {
        check("first-mouse: the click was delivered without the override", (standIn?.clicks ?? 0) > 0)
    } else {
        check("first-mouse: the click reached onSegmentClick", clickedRole != nil)
        check("first-mouse: it resolved to the clicked segment", clickedRole == .place)
        // The rest of the shipped flow, on the same click: activating the host
        // resigned the panel, and the resign observer took the card down.
        check("first-mouse: the same click handed key back to the host", host.isKeyWindow)
        check("first-mouse: the resign observer dismissed the card", controller.isShowing == false)
    }
    controller.dismiss()
    host.close()
    pump(0.1)
}

// MARK: - Entry

@main
enum Probe {
    @MainActor static func main() {
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let cardArms: [String: @MainActor () -> Void] = [
            "show": armShow,
            "esc": armEsc,
            "click-outside": armClickOutside,
            "switch": armSwitch,
            "dismiss": armDismiss,
        ]

        let requested = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
        let broken = CommandLine.arguments.contains("break")

        if requested == "first-mouse" {
            armFirstMouse(broken: broken)
        } else if let arm = cardArms[requested] {
            // The five card arms' negative control: a panel that refuses key.
            // Every arm asserts the card took key as its precondition, so a
            // control that stopped failing would mean the arm no longer
            // measures the keyboard at all.
            PalettePanel.refusesKey = broken
            arm()
        } else {
            print("usage: cardkeytest <\(cardArms.keys.sorted().joined(separator: "|"))|first-mouse> [break]")
            exit(2)
        }

        if failures.isEmpty {
            print("\(requested)\(broken ? " (break)" : ""): all checks pass")
            exit(0)
        } else {
            print("\(requested)\(broken ? " (break)" : ""): \(failures.count) check(s) failed")
            exit(1)
        }
    }
}
