"""Compile the shipped invalidation wiring, without terminal or state dependencies."""
import re
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
# The field and its initializer are absent in the pre-fix baseline.
field = re.search(r"    private var contentLayoutObservation: NSKeyValueObservation\?", source)
assignment = re.search(r"        contentLayoutObservation = window.observe\(.*?\n        \}", source, re.S)
if sys.argv[3:] == ["--without-observer"]:
    assignment = None
elif sys.argv[3:]:
    raise SystemExit("Unknown probe option")
resize = re.search(r"    func windowDidResize\(_.*?\n    \}", source, re.S).group()
Path(sys.argv[2]).write_text("""import AppKit
final class ProbeController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let sidebar: ProbeSidebar
    var onSessionChange: (() -> Void)?
""" + (field.group() if field else "") + """
    init(window: NSWindow, sidebar: ProbeSidebar) {
        self.window = window
        self.sidebar = sidebar
        super.init()
        window.delegate = self
""" + (assignment.group() if assignment else "") + """
    }
""" + resize + "\n}\n")
