import AppKit

final class ProbeWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// An AppKit content controller that records the geometry consumed at layout.
// The production controller must invalidate it when native chrome changes.
final class ProbeSidebar: NSViewController {
    var laidOutBand: CGFloat = -1
    override func loadView() { view = NSView() }
    override func viewDidLayout() {
        super.viewDidLayout()
        if let window = view.window {
            laidOutBand = window.frame.height - window.contentLayoutRect.height
        }
    }
}

@main
private enum TabCloseLayoutProbe {
    static func drain() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3)) }
    static func require(_ value: Bool, _ message: String) {
        guard value else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        func makeWindow() -> ProbeWindow {
            let window = ProbeWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.tabbingIdentifier = "baia.tab-close-layout.probe"
            window.tabbingMode = .preferred
            return window
        }
        let first = makeWindow(), second = makeWindow()
        let host = ProbeSidebar()
        first.contentViewController = host
        first.setContentSize(NSSize(width: 600, height: 400))
        let secondHost = ProbeSidebar()
        second.contentViewController = secondHost
        second.setContentSize(NSSize(width: 600, height: 400))
        let controller = ProbeController(window: first, sidebar: host)
        let secondController = ProbeController(window: second, sidebar: secondHost)
        withExtendedLifetime((controller, secondController)) {
            first.orderFrontRegardless()
            drain()
            host.view.needsLayout = true
            host.view.layoutSubtreeIfNeeded()
            let singleBand = host.laidOutBand
            let frame = first.frame
            first.addTabbedWindow(second, ordered: .above)
            second.orderFrontRegardless()
            drain()
            let tabbedBand = first.frame.height - first.contentLayoutRect.height
            require(tabbedBand > singleBand, "native tab group did not add chrome")
            require(abs(secondHost.laidOutBand - tabbedBand) < 0.1,
                "new tab host band \(secondHost.laidOutBand), expected \(tabbedBand)")
            first.tabGroup?.selectedWindow = first
            first.orderFrontRegardless()
            drain()
            require(abs(host.laidOutBand - tabbedBand) < 0.1,
                "original tab host band \(host.laidOutBand), expected \(tabbedBand) after opening sibling and returning")
            require(first.frame == frame, "opening sibling unexpectedly resized the window")
            print("PASS: open 1 → 2 tabs, new and original host bands \(tabbedBand), window frame unchanged")
            second.close()
            drain()
            require(first.frame == frame, "close unexpectedly resized the window")
            let actualBand = first.frame.height - first.contentLayoutRect.height
            require(abs(actualBand - singleBand) < 0.1, "native tab bar did not collapse")
            require(abs(host.laidOutBand - singleBand) < 0.1,
                "stale host band \(host.laidOutBand), expected \(singleBand) after closing final sibling tab")
            print("PASS: close 2 → 1 tabs, host band \(tabbedBand) → \(host.laidOutBand), window frame unchanged")
            first.close()
        }
    }
}
