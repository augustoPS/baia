// Two arms, both about the same question: the black band above a full-screen
// window on a notched display.
//
//   geometry  is that band inside the window or outside it
//   sample    what colour is anything, read out of a screenshot
//
// The band was first read off a screenshot as 39 pt of pure #000000 sitting over
// a window whose darkest surface is #1D1D1D, which looks like a letterbox and
// invites a fix: paint it with the theme background, extend the tab bar into it,
// give the window a backgroundColor. Every one of those is wasted work if the
// band is not the window's to draw, and a screenshot cannot tell the two apart.
// This measures it instead.

import AppKit

// MARK: - geometry

/// Whether the strip above a full-screen window belongs to the window.
///
/// Asserts the answer rather than only printing it, because the answer is load
/// bearing: the design note in `Verified 2026-07-27` says the strip is
/// unpaintable, and a macOS that changes its mind should fail here rather than
/// leave that note quietly wrong.
///
/// Skips rather than fails on a display with no notch. An external monitor has
/// no safe-area inset and its full-screen windows fill the whole frame, so there
/// is no strip to ask about and a failure would only be reporting the monitor.
@MainActor
final class GeometryArm: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var ok = false

    func applicationDidFinishLaunching(_: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "fullscreen strip probe"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        report(stage: "windowed")

        NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                self.report(stage: "full screen")
                self.judge()
                exit(self.ok ? 0 : 1)
            }
        }

        // A beat before the toggle, so the window is on screen and has a screen
        // to be full on. The transition itself is what the notification waits
        // for; nothing here polls it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.window.toggleFullScreen(nil) }
    }

    private func report(stage: String) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        print("  === \(stage) ===")
        print("  screen.frame           \(screen.frame)")
        print("  screen.visibleFrame    \(screen.visibleFrame)")
        print("  screen.safeAreaInsets  top \(screen.safeAreaInsets.top)")
        print("  window.frame           \(window.frame)")
        print("  window.contentLayout   \(window.contentLayoutRect)")
        if let content = window.contentView {
            print("  contentView.safeArea   top \(content.safeAreaInsets.top)")
        }
        print("  styleMask.fullScreen   \(window.styleMask.contains(.fullScreen))")
    }

    private func judge() {
        guard let screen = window.screen ?? NSScreen.main else { return }

        guard screen.safeAreaInsets.top > 0 else {
            print("  SKIP: this display has no safe-area inset, so it has no notch")
            print("        and a full-screen window has no strip above it to explain.")
            ok = true
            return
        }

        let strip = screen.frame.maxY - window.frame.maxY
        let inset = window.contentView?.safeAreaInsets.top ?? 0
        print("  strip above the window: \(strip) pt")
        print("  content inset inside the window: \(inset) pt")

        // Outside the window is the answer this was written against: the window
        // is handed `visibleFrame`, which in full screen already has the menu
        // bar strip taken out of it, and nothing insets the content within the
        // window because there is nothing up there to avoid.
        if strip > 0, inset == 0 {
            print("  PASS: the strip is OUTSIDE the window. Nothing baia draws can reach it.")
            ok = true
        } else if strip == 0, inset > 0 {
            print("  FAIL: the strip is now INSIDE the window, inset by the safe area.")
            print("        It became paintable. The note saying otherwise is stale, and")
            print("        the window background is what shows there.")
        } else {
            print("  FAIL: neither shape. strip=\(strip) inset=\(inset)")
        }
    }
}

// MARK: - sample

/// Reads pixels out of a screenshot, because "it looks black" and "it is
/// #000000" are different claims and only one of them settles an argument about
/// whether a surface matches the theme.
///
/// Coordinates are in image pixels with the origin at the top left, which is
/// where a screenshot's own coordinates are. On a 2x capture that is twice the
/// point value, so a band measured here as 78 px is 39 pt.
func sampleArm(_ arguments: [String]) -> Bool {
    guard let path = arguments.first else {
        print("usage: fullscreenstrip sample <image> [x,y ...]")
        return false
    }
    guard let image = NSImage(contentsOfFile: path),
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff)
    else {
        print("  FAIL: could not read \(path)")
        return false
    }

    print("  \(path)")
    print("  \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) px")

    for pair in arguments.dropFirst() {
        let parts = pair.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 2 else {
            print("  FAIL: \(pair) is not x,y")
            return false
        }
        let (x, y) = (parts[0], parts[1])
        guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh,
              let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        else {
            print("  FAIL: \(x),\(y) is outside the image")
            return false
        }
        let r = Int((colour.redComponent * 255).rounded())
        let g = Int((colour.greenComponent * 255).rounded())
        let b = Int((colour.blueComponent * 255).rounded())
        print(String(format: "  %5d,%-5d  #%02X%02X%02X  rgb(%d, %d, %d)", x, y, r, g, b, r, g, b))
    }

    // Where a solid band at the top gives way to anything else, walked down the
    // middle column. The measurement the geometry arm then explains.
    var lastDark = -1
    let middle = bitmap.pixelsWide / 2
    for y in 0 ..< min(400, bitmap.pixelsHigh) {
        guard let colour = bitmap.colorAt(x: middle, y: y)?.usingColorSpace(.sRGB) else { break }
        let luminance = colour.redComponent + colour.greenComponent + colour.blueComponent
        if luminance < 0.02 { lastDark = y } else { break }
    }
    if lastDark >= 0 {
        let px = lastDark + 1
        print("  black band at the top spans y 0...\(lastDark), \(px) px, \(Double(px) / 2) pt at 2x")
    } else {
        print("  no black band at the top of the middle column")
    }
    return true
}

// MARK: - entry

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "geometry":
    let app = NSApplication.shared
    // .regular and not .accessory: this arm takes the display, the way
    // footer-corners' own fullscreen arm does. A full-screen transition is not
    // something an accessory app is given.
    app.setActivationPolicy(.regular)
    let arm = GeometryArm()
    app.delegate = arm
    app.run()
case "sample":
    exit(sampleArm(Array(arguments.dropFirst())) ? 0 : 1)
default:
    print("usage: fullscreenstrip geometry")
    print("       fullscreenstrip sample <image> [x,y ...]")
    exit(1)
}
