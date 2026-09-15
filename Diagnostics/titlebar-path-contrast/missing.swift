import AppKit
import PaneChrome

@main
private enum MissingTreatmentBaseline {
    @MainActor
    static func main() {
        let accessory = TitlebarPathAccessory(theme: .darkPastel)
        guard !Mirror(reflecting: accessory).children.contains(where: { $0.label == "resolvedChrome" }) else {
            fputs("FAIL: production accessory now has chrome-aware treatment\n", stderr)
            exit(1)
        }
        accessory.loadView()
        guard let stack = accessory.view.subviews.first as? NSStackView,
              let label = stack.arrangedSubviews.compactMap({ $0 as? NSTextField }).first,
              let icon = stack.arrangedSubviews.compactMap({ $0 as? NSImageView }).first else {
            fputs("FAIL: production accessory hierarchy changed\n", stderr)
            exit(1)
        }
        guard label.shadow == nil, icon.shadow == nil else {
            fputs("FAIL: glass edge treatment is no longer missing\n", stderr)
            exit(1)
        }
        print("RED baseline confirmed: production label and icon have no edge treatment")
    }
}
