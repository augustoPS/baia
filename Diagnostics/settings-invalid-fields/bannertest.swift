import AppKit
import BaiaSettings
import Foundation

// Does SettingsRecoveryBanner name a wrong-type field the decoder already
// reported, keep a valid sibling, and hide again when that field is written
// correctly — without claiming every rejected value became its default?
//
// `Sources/SettingsWindowController.swift`'s banner class is compiled
// verbatim (extracted from the `Recovery banner` mark). The window
// controller's `refreshRecoveryState()` calls this same `present` with the
// store's inspect/load URL, so a hidden banner here is a hidden banner in
// Settings. Package tests already prove `invalidKeys` and sibling apply;
// they cannot see this view. The control build is HEAD, where `present`
// only inspects document shape and write failure.
//
// **No window on screen, no focus taken.** The banner is an `NSView` that
// is never installed in a window. The activation policy is `.accessory`.
// There is no `orderFront`, `makeKey`, `activate` or `pkill` in this file.

var failures: [String] = []

func expect(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

func seedS03(at url: URL) {
    let text = """
    {
      "fontSize": "big",
      "windowPadding": 24
    }
    """
    try! text.write(to: url, atomically: true, encoding: .utf8)
}

func seedClean(at url: URL) {
    let text = """
    {
      "fontSize": 12,
      "windowPadding": 24
    }
    """
    try! text.write(to: url, atomically: true, encoding: .utf8)
}

func seedClamp(at url: URL) {
    let text = """
    {
      "backgroundOpacity": 1.5,
      "windowPadding": 24
    }
    """
    try! text.write(to: url, atomically: true, encoding: .utf8)
}

func withStore(_ write: (URL) -> Void) -> SettingsStore {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "baia-invalid-fields-\(UUID().uuidString)", directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "config.json")
    write(url)
    return SettingsStore(fileURL: url)
}

func present(_ banner: SettingsRecoveryBanner, store: SettingsStore, failure: SettingsWriteFailure? = nil) {
    banner.present(state: store.inspect(), failure: failure, fileURL: store.url)
}

func bannerText(_ banner: SettingsRecoveryBanner) -> String {
    var texts: [String] = []
    func walk(_ view: NSView) {
        if let field = view as? NSTextField, !field.isEditable {
            let value = field.stringValue
            if !value.isEmpty { texts.append(value) }
        }
        view.subviews.forEach(walk)
    }
    walk(banner)
    return texts.joined(separator: " ")
}

func button(_ banner: SettingsRecoveryBanner, titled title: String) -> NSButton? {
    var found: NSButton?
    func walk(_ view: NSView) {
        if let candidate = view as? NSButton, candidate.title == title {
            found = candidate
        }
        view.subviews.forEach(walk)
    }
    walk(banner)
    return found
}

func claimsDefault(_ text: String) -> Bool {
    text.range(of: #"\bdefault\b"#, options: .regularExpression) != nil
}

func repairButton(_ banner: SettingsRecoveryBanner) -> NSButton? {
    button(banner, titled: "Repair Configuration…")
}

func revealButton(_ banner: SettingsRecoveryBanner) -> NSButton? {
    button(banner, titled: "Reveal File")
}

func retryButton(_ banner: SettingsRecoveryBanner) -> NSButton? {
    button(banner, titled: "Retry Failed Undo/Redo")
}

/// S03: string `fontSize` plus padding 24. The banner must name fontSize,
/// leave padding unblamed, and not say the value defaulted.
func discovery() {
    let store = withStore(seedS03)
    let result = store.load()
    expect(result.invalidKeys == ["fontSize"], "invalidKeys are \(result.invalidKeys), expected [fontSize]")
    expect(result.settings.windowPadding == 24, "windowPadding is \(result.settings.windowPadding), expected 24")
    expect(
        result.settings.fontSize == Settings.defaultSettings.fontSize,
        "fontSize is \(result.settings.fontSize), expected the fallback \(Settings.defaultSettings.fontSize)"
    )

    let banner = SettingsRecoveryBanner()
    present(banner, store: store)
    let text = bannerText(banner)
    expect(!banner.isHidden, "banner stayed hidden for a wrong-type fontSize")
    expect(text.contains("`fontSize`"), "banner text does not name fontSize: \(text)")
    expect(!text.contains("windowPadding"), "banner blamed the valid sibling: \(text)")
    expect(!claimsDefault(text), "banner claimed a default for a rejected value: \(text)")
    if !banner.isHidden {
        expect(repairButton(banner)?.isHidden == true, "Repair was offered for a valid JSON object")
        expect(revealButton(banner)?.isHidden == false, "Reveal File was hidden")
    }
}

/// Opacity 1.5 is clamped to 1 and still reported. The banner must not
/// describe that as a default.
func clampWording() {
    let store = withStore(seedClamp)
    let result = store.load()
    expect(result.invalidKeys == ["backgroundOpacity"], "invalidKeys are \(result.invalidKeys)")
    expect(result.settings.backgroundOpacity == 1, "1.5 clamped to \(result.settings.backgroundOpacity), not 1")
    expect(result.settings.windowPadding == 24, "windowPadding is \(result.settings.windowPadding), expected 24")

    let banner = SettingsRecoveryBanner()
    present(banner, store: store)
    let text = bannerText(banner)
    expect(!banner.isHidden, "banner stayed hidden for a clamped opacity")
    expect(text.contains("`backgroundOpacity`"), "banner text does not name backgroundOpacity: \(text)")
    expect(!claimsDefault(text), "banner claimed a default for a clamped value: \(text)")
}

/// Writing a valid fontSize through the store — the same patch Settings uses
/// — clears the warning and keeps padding 24.
func correction() {
    let store = withStore(seedS03)
    let banner = SettingsRecoveryBanner()
    present(banner, store: store)
    expect(!banner.isHidden, "warning never appeared, so clearing it proves nothing")

    switch store.patch([.fontSize(12)]) {
    case let .failure(failure):
        expect(false, "correction write failed: \(failure.message)")
    case let .success(result):
        expect(result.invalidKeys.isEmpty, "invalidKeys after correction: \(result.invalidKeys)")
        expect(result.settings.fontSize == 12, "fontSize is \(result.settings.fontSize), expected 12")
        expect(result.settings.windowPadding == 24, "windowPadding was rewritten to \(result.settings.windowPadding)")
    }
    present(banner, store: store)
    expect(banner.isHidden, "banner stayed up after fontSize was written correctly: \(bannerText(banner))")
}

/// A later valid write of another key leaves the invalid field in the file
/// and the warning up.
func siblingWrite() {
    let store = withStore(seedS03)
    switch store.patch([.windowPadding(16)]) {
    case let .failure(failure):
        expect(false, "sibling write failed: \(failure.message)")
    case let .success(result):
        expect(result.settings.windowPadding == 16, "windowPadding is \(result.settings.windowPadding), expected 16")
        expect(result.invalidKeys == ["fontSize"], "fontSize was dropped from invalidKeys: \(result.invalidKeys)")
    }
    let banner = SettingsRecoveryBanner()
    present(banner, store: store)
    let text = bannerText(banner)
    expect(!banner.isHidden, "banner hid after a sibling write left fontSize invalid")
    expect(text.contains("`fontSize`"), "banner text does not name fontSize after sibling write: \(text)")
}

/// Decoder contract the banner is not allowed to invent: the sibling applied.
func siblingApplied() {
    let result = withStore(seedS03).load()
    expect(result.settings.windowPadding == 24, "windowPadding is \(result.settings.windowPadding), expected 24")
    expect(
        result.settings.fontSize == Settings.defaultSettings.fontSize,
        "fontSize is \(result.settings.fontSize), expected \(Settings.defaultSettings.fontSize)"
    )
    expect(result.invalidKeys == ["fontSize"], "invalidKeys are \(result.invalidKeys)")
}

func cleanHides() {
    let banner = SettingsRecoveryBanner()
    present(banner, store: withStore(seedClean))
    expect(banner.isHidden, "banner showed on a valid file: \(bannerText(banner))")
}

func malformedShows() {
    let store = withStore { url in
        try! Data("{ broken".utf8).write(to: url)
    }
    let banner = SettingsRecoveryBanner()
    present(banner, store: store)
    let text = bannerText(banner)
    expect(!banner.isHidden, "banner stayed hidden for malformed JSON")
    expect(text.contains("not valid JSON"), "malformed copy missing: \(text)")
    expect(repairButton(banner)?.isHidden == false, "Repair was hidden for a broken document")
}

func writeFailureShows() {
    let banner = SettingsRecoveryBanner()
    present(banner, store: withStore(seedClean), failure: .temporaryWrite)
    let text = bannerText(banner)
    expect(!banner.isHidden, "banner stayed hidden for a write failure")
    expect(text.contains("not saved"), "write-failure copy missing: \(text)")
    expect(repairButton(banner)?.isHidden == true, "Repair was offered for a write failure on valid JSON")
}

func historyRetry() {
    let banner = SettingsRecoveryBanner()
    present(banner, store: withStore(seedClean))
    expect(banner.isHidden, "clean file already showed a banner")
    banner.offerHistoryRetry(true)
    expect(!banner.isHidden, "retry offer did not show the banner")
    expect(retryButton(banner)?.isHidden == false, "Retry Failed Undo/Redo stayed hidden")
    expect(repairButton(banner)?.isHidden == true, "Repair was offered for a retry-only banner")
}

@main
enum Probe {
    @MainActor static func main() {
        let arms: [String: @MainActor () -> Void] = [
            "discovery": discovery,
            "clamp-wording": clampWording,
            "correction": correction,
            "sibling-write": siblingWrite,
            "sibling-applied": siblingApplied,
            "clean-hides": cleanHides,
            "malformed-shows": malformedShows,
            "write-failure": writeFailureShows,
            "history-retry": historyRetry,
        ]

        let name = CommandLine.arguments.dropFirst().first ?? ""
        guard let arm = arms[name] else {
            print("usage: bannertest <arm>; arms: \(arms.keys.sorted().joined(separator: " "))")
            exit(2)
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        arm()
        if failures.isEmpty {
            print("\(name): pass")
            exit(0)
        }
        print("\(name): FAIL")
        for failure in failures { print("  \(failure)") }
        exit(1)
    }
}
