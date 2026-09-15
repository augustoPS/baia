import AppKit
import PaneChrome

@MainActor
private func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

@MainActor
private func views(in accessory: TitlebarPathAccessory) -> (NSTextField, NSImageView) {
    accessory.loadView()
    guard let stack = accessory.view.subviews.compactMap({ $0 as? NSStackView }).first else {
        fail("production accessory has no stack")
    }
    guard let label = stack.arrangedSubviews.compactMap({ $0 as? NSTextField }).first else {
        fail("production accessory has no path label")
    }
    guard let icon = stack.arrangedSubviews.compactMap({ $0 as? NSImageView }).first else {
        fail("production accessory has no folder icon")
    }
    return (label, icon)
}

@MainActor
private func edgeWhite(_ shadow: NSShadow?, _ context: String) -> Bool {
    guard let colour = shadow?.shadowColor as? NSColor,
          let rgb = colour.usingColorSpace(.sRGB) else {
        fail("\(context) has no sRGB edge")
    }
    return rgb.redComponent > 0.5
}

@MainActor
private func checkTheme(_ name: String, theme: PaneTheme, expectsWhiteEdge: Bool) {
    let flat = TitlebarPathAccessory(theme: theme, resolvedChrome: .flat)
    let flatViews = views(in: flat)
    guard flatViews.0.shadow == nil, flatViews.1.shadow == nil else {
        fail("\(name) flat has edge treatment")
    }

    let glass = TitlebarPathAccessory(theme: theme, resolvedChrome: .glass(.dark))
    let glassViews = views(in: glass)
    guard edgeWhite(glassViews.0.shadow, "\(name) glass label") == expectsWhiteEdge else {
        fail("\(name) label edge is not opposite-luminance")
    }
    guard edgeWhite(glassViews.1.shadow, "\(name) glass icon") == expectsWhiteEdge else {
        fail("\(name) icon edge is not opposite-luminance")
    }
}

@MainActor
private func run() {
    let dawnfox = PaneTheme(
        background: .eightBit(0xFA, 0xF4, 0xED),
        foreground: .eightBit(0x57, 0x52, 0x79),
        focusedAccent: .eightBit(0x90, 0x76, 0xAA),
        ansi: []
    )

    checkTheme("Dark Pastel", theme: .darkPastel, expectsWhiteEdge: false)
    checkTheme("Dawnfox", theme: dawnfox, expectsWhiteEdge: true)

    let accessory = TitlebarPathAccessory(theme: .darkPastel, resolvedChrome: .glass(.dark))
    let identity = ObjectIdentifier(accessory)
    let state = views(in: accessory)
    guard state.0.shadow != nil, state.1.shadow != nil else { fail("live fixture starts without glass edge") }
    accessory.resolvedChrome = .flat
    guard ObjectIdentifier(accessory) == identity else { fail("live switch recreated accessory") }
    guard state.0.shadow == nil, state.1.shadow == nil else { fail("live flat switch kept edge") }
    accessory.resolvedChrome = .glass(.light)
    guard state.0.shadow != nil, state.1.shadow != nil else { fail("live glass switch did not restore edge") }

    print("PASS: flat is untreated; glass edges both label and icon in the opposite luminance direction")
    print("PASS: live glass/flat switching updates one accessory instance")
}

run()
