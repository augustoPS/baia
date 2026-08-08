import AppKit

// Does the design panel's `wantsKey` flag come down on every path that ends an
// editing session? One arm per path, plus a `break` variant of each that strips
// the two window-level overrides and is expected to fail. See README.md.

// MARK: - The panel under test

/// The shipped semantics: `DesignPanel` in `Sources/DesignPanelController.swift`.
///
/// **Retyped rather than compiled verbatim, unlike every other probe here**, and
/// the README says why and what holds it honest: `DesignPanel` shares a file with
/// `DesignPanelController`, which reaches `ConfigurationCenter` and therefore the
/// whole app target, so there is nothing to compile in isolation. The four lines
/// that decide the behaviour are reproduced exactly, and `run.sh` greps the
/// shipped file for each of them before running a single arm.
/// Both the shipped panel and its control, told apart by ``lowersOnWindowEvents``.
///
/// One class rather than two, because a subclass overriding `resignKey()` to
/// *not* call the fix has no way to reach `NSPanel`'s implementation past its own
/// superclass's: Swift has no `super.super`, and the alternatives (duplicating
/// the class, or reaching for the Objective-C runtime) both put the control
/// further from the code it is meant to be the same as. A flag consulted at the
/// one line that differs keeps the two versions a single readable diff.
///
/// `false` is the panel exactly as it was before the fix: the flag raised by a
/// hex field's click, and lowered only by that field's end-of-editing action.
/// Every arm below ends its session by a path that fires no control action, so
/// "the action never ran" is modelled by no lowering happening at all — which is
/// the defect exactly. After Escape or a close, the flag stayed up with no
/// further event able to bring it down.
final class KeyPanel: NSPanel {
    var wantsKey = false

    /// The fix. See ``DesignPanel`` in `Sources/DesignPanelController.swift`.
    var lowersOnWindowEvents = true

    override var canBecomeKey: Bool { wantsKey }

    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        if lowersOnWindowEvents { wantsKey = false }
    }

    override func orderOut(_ sender: Any?) {
        if lowersOnWindowEvents { wantsKey = false }
        super.orderOut(sender)
    }
}

// MARK: - Harness

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var failures: [String] = []

func check(_ label: String, _ ok: Bool) {
    if ok {
        print("  ok    \(label)")
    } else {
        print("  FAIL  \(label)")
        failures.append(label)
    }
}

/// Lets the window server act on what was just asked for.
///
/// A real run loop rather than a `sleep`: key transitions are delivered as
/// events, and a process that blocks its main thread never receives them, so a
/// sleeping probe reads every flag as though nothing had happened.
func settle(_ seconds: TimeInterval = 0.35) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

func makePanel(broken: Bool) -> KeyPanel {
    let panel = KeyPanel(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
        // The shipped mask. `.titled` and `.closable` matter to the close arms:
        // `performClose(_:)` is a no-op on a panel with no close button, so a
        // borderless probe would pass that arm by never testing it.
        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.lowersOnWindowEvents = !broken
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.hidesOnDeactivate = false
    return panel
}

/// A panel on screen with the flag raised and key taken, which is what a click
/// into a hex field leaves behind.
func editingPanel(broken: Bool) -> KeyPanel {
    let panel = makePanel(broken: broken)
    panel.orderFront(nil)
    settle()
    panel.wantsKey = true
    panel.makeKey()
    settle()
    return panel
}

// MARK: - Arms

/// Every arm asserts the same three things after its own ending: the flag is
/// down, `canBecomeKey` answers false, and a later click cannot take key.
///
/// The three are not one assertion written out. `canBecomeKey` is what AppKit
/// actually consults, so asserting only the boolean would pass a version that
/// lowered the flag while overriding `canBecomeKey` to something else; and
/// asking the panel to become key is what says the first two describe the
/// window's real behaviour rather than two fields agreeing with each other.
///
/// **The third check is weaker in the three arms that end with the panel off
/// screen, and that is a property of AppKit rather than a hole in the probe.** A
/// window that has been closed or ordered out cannot become key whatever its
/// `canBecomeKey` says, so in `order-out`, `perform-close` and
/// `order-out-never-key` the control fails on the first two checks and *passes*
/// the third. The leak those arms describe is real but latent: the flag stays up
/// while the panel is away, and the theft happens on the next open.
///
/// Only ``armResignKey`` (panel still on screen) and ``armReopen`` (panel brought
/// back) have their controls fail all three, and that is why `reopen` exists as a
/// separate arm rather than being folded into `order-out`: it is the one that
/// carries an off-screen leak through to the moment it would cost something.
func assertRefusesKeyAgain(_ panel: KeyPanel, _ arm: String) {
    check("\(arm): flag is down", panel.wantsKey == false)
    check("\(arm): canBecomeKey is false", panel.canBecomeKey == false)
    panel.makeKey()
    settle()
    check("\(arm): a later click cannot steal key", panel.isKeyWindow == false)
}

/// Escape, and clicking away. Both end the editing session by taking key
/// elsewhere while firing no control action, which is the first of the two leaks.
func armResignKey(broken: Bool) {
    print("resign-key")
    let panel = editingPanel(broken: broken)
    check("resign-key: took key while editing", panel.isKeyWindow)

    // Another window takes key. That is what Escape amounts to from this panel's
    // side, and what clicking back into a pane does.
    let other = NSWindow(
        contentRect: NSRect(x: 500, y: 400, width: 240, height: 120),
        styleMask: [.titled, .closable], backing: .buffered, defer: false
    )
    other.isReleasedWhenClosed = false
    other.makeKeyAndOrderFront(nil)
    settle()

    assertRefusesKeyAgain(panel, "resign-key")
    other.close()
    panel.close()
}

/// ⌥⌘D while a field is being edited: the controller calls `orderOut` directly.
func armOrderOut(broken: Bool) {
    print("order-out")
    let panel = editingPanel(broken: broken)
    check("order-out: took key while editing", panel.isKeyWindow)
    panel.orderOut(nil)
    settle()
    assertRefusesKeyAgain(panel, "order-out")
    panel.close()
}

/// The titlebar close button, which drives `performClose(_:)` → `close()`.
///
/// A separate arm from `order-out` because it is a different entry point that
/// could plausibly bypass both hooks. It does not — `close()` calls `orderOut(_:)`
/// and fires `resignKey()` — and that is a fact about AppKit this arm exists to
/// keep checking rather than to assume.
func armPerformClose(broken: Bool) {
    print("perform-close")
    let panel = editingPanel(broken: broken)
    check("perform-close: took key while editing", panel.isKeyWindow)
    panel.performClose(nil)
    settle()
    assertRefusesKeyAgain(panel, "perform-close")
}

/// Ordering out a panel that was never key.
///
/// The path `resignKey` alone cannot cover: no key was held, so no key is
/// resigned, and only the `orderOut` override brings the flag down. Opening the
/// panel, clicking a hex field, then closing without the panel ever having
/// become key is unusual but reachable, and the arm exists so the two overrides
/// are each shown to be load-bearing rather than one being redundant.
func armOrderOutNeverKey(broken: Bool) {
    print("order-out-never-key")
    let panel = makePanel(broken: broken)
    panel.orderFront(nil)
    settle()
    // Raised without the panel ever taking key.
    panel.wantsKey = true
    check("order-out-never-key: never became key", panel.isKeyWindow == false)
    panel.orderOut(nil)
    settle()
    assertRefusesKeyAgain(panel, "order-out-never-key")
    panel.close()
}

/// Closed mid-edit, then reopened with ⌥⌘D.
///
/// The state the owner actually reaches: dial, type a hex, close, come back
/// later. A panel that reopened with the flag still up would take key from the
/// pane on the first click anywhere in it, including a slider.
func armReopen(broken: Bool) {
    print("reopen")
    let panel = editingPanel(broken: broken)
    panel.orderOut(nil)
    settle()
    // Back again, the way `toggle()` brings it back: `orderFront`, never
    // `makeKeyAndOrderFront`.
    panel.orderFront(nil)
    settle()
    check("reopen: reopened without taking key", panel.isKeyWindow == false)
    assertRefusesKeyAgain(panel, "reopen")
    panel.close()
}

// MARK: - Entry

let arms: [String: (Bool) -> Void] = [
    "resign-key": armResignKey,
    "order-out": armOrderOut,
    "perform-close": armPerformClose,
    "order-out-never-key": armOrderOutNeverKey,
    "reopen": armReopen,
]

let requested = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let broken = CommandLine.arguments.contains("break")

guard let arm = arms[requested] else {
    print("usage: keytest <\(arms.keys.sorted().joined(separator: "|"))> [break]")
    exit(2)
}

arm(broken)

if failures.isEmpty {
    print("\(requested)\(broken ? " (break)" : ""): all checks pass")
    exit(0)
} else {
    print("\(requested)\(broken ? " (break)" : ""): \(failures.count) check(s) failed")
    exit(1)
}
