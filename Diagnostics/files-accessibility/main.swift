import AppKit
import GitWorkspace

var failures = 0

func check(_ passed: Bool, _ message: String) {
    if passed {
        print("  ok    \(message)")
    } else {
        failures += 1
        print("  FAIL  \(message)")
    }
}

func actionNames(of element: NSAccessibilityElement) -> [NSAccessibility.Action] {
    let selector = NSSelectorFromString("accessibilityActionNames")
    guard element.responds(to: selector),
          let value = element.perform(selector)?.takeUnretainedValue()
    else { return [] }
    return value as? [NSAccessibility.Action] ?? []
}

@MainActor
func children(of rows: FileTreeRowsView) -> [NSAccessibilityElement] {
    rows.accessibilityChildren() as? [NSAccessibilityElement] ?? []
}

@MainActor
func visibleChildren(of rows: FileTreeRowsView) -> [NSAccessibilityElement] {
    rows.accessibilityVisibleChildren() as? [NSAccessibilityElement] ?? []
}

@MainActor
func makeRows(height: Double = 36) -> (NSScrollView, FileTreeRowsView) {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: height))
    scroll.hasVerticalScroller = false
    let rows = FileTreeRowsView(frame: scroll.contentView.bounds)
    scroll.documentView = rows
    scroll.layoutSubtreeIfNeeded()
    return (scroll, rows)
}

@MainActor
func node(_ name: String, path: String? = nil, children: [FileTreeNode] = []) -> FileTreeNode {
    FileTreeNode(
        name: RepositoryPath(name),
        path: RepositoryPath(path ?? name),
        isDirectory: !children.isEmpty,
        children: children
    )
}

struct TraversalMeasurement {
    let elapsedNanoseconds: UInt64
    let checksum: Int
}

/// Walks the same production AX properties a client reads from a flat outline
/// with one disclosed directory. Comparing four times as many children catches
/// a path lookup or parent lookup that scans from the start for every row.
@MainActor
func measureOutlineTraversal(childCount: Int, passes: Int) -> TraversalMeasurement {
    let (_, rows) = makeRows(height: 54)
    let root = RepositoryPath("root")
    rows.tree = [node(
        "root",
        children: (0 ..< childCount).map {
            node(String(format: "file-%05d.swift", $0), path: String(format: "root/file-%05d.swift", $0))
        }
    )]
    rows.expanded = [root]
    rows.onSelect = { _ in true }
    let semanticRows = children(of: rows)
    precondition(semanticRows.count == childCount + 1)

    var checksum = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0 ..< passes {
        for (expectedIndex, row) in semanticRows.enumerated() {
            checksum &+= row.accessibilityIndex()
            checksum &+= row.accessibilityLabel()?.utf8.count ?? 0
            checksum &+= (row.accessibilityValue() as? String)?.utf8.count ?? 0
            checksum &+= Int(row.accessibilityFrame().height)
            checksum &+= row.accessibilityDisclosureLevel()
            checksum &+= row.isAccessibilityEnabled() ? 1 : 0
            checksum &+= row.isAccessibilitySelected() ? 1 : 0
            if expectedIndex > 0,
               row.accessibilityDisclosedByRow() as? NSAccessibilityElement === semanticRows[0] {
                checksum &+= 1
            }
        }
        checksum &+= (semanticRows[0].accessibilityDisclosedRows() as? [NSAccessibilityElement])?.count ?? 0
    }
    return TraversalMeasurement(
        elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - start,
        checksum: checksum
    )
}

@MainActor
func medianOutlineTraversal(childCount: Int, passes: Int) -> TraversalMeasurement {
    let samples = (0 ..< 3).map { _ in
        measureOutlineTraversal(childCount: childCount, passes: passes)
    }
    return samples.sorted { $0.elapsedNanoseconds < $1.elapsedNanoseconds }[1]
}

@main
enum FilesAccessibilityFixture {
    @MainActor static func main() {
        let (scroll, rows) = makeRows()
        rows.anchorPath = "/repositories/A"
        rows.tree = [
            node("Sources", children: [node("main.swift", path: "Sources/main.swift")]),
            node("README.md"),
        ]

        print("=== production outline semantics ===")
        check(rows.window == nil && scroll.window == nil, "the fixture creates no window")
        check(!rows.acceptsFirstResponder, "the drawn rows still refuse first responder")
        check(rows.isAccessibilityElement(), "the rows view is an accessibility element")
        check(rows.accessibilityRole() == .outline, "the container role is outline")
        check(rows.accessibilityLabel() == "Files", "the outline has a stable spoken label")

        let initial = children(of: rows)
        check(initial.count == 2, "one semantic child exists per currently flattened node")
        check((rows.accessibilityRows() as? [NSAccessibilityElement])?.count == 2, "the outline rows attribute exposes the same semantic rows")
        if initial.count == 2 {
            check(initial.allSatisfy { $0.accessibilityRole() == .row }, "every semantic child role is row")
            check(initial.map { $0.accessibilityIndex() } == [0, 1], "every semantic row exposes its flattened index")
            check(initial.allSatisfy { actionNames(of: $0).contains(.press) }, "every row exposes AXPress")
            check(initial.map { $0.accessibilityLabel() ?? "" } == ["Sources/", "README.md"], "labels preserve the drawn filenames")
            check(initial.map { $0.accessibilityValue() as? String ?? "" } == ["Sources", "README.md"], "values expose full repository-relative paths")
            check(initial.map { $0.accessibilityDisclosureLevel() } == [0, 0], "top-level rows expose hierarchy level zero")
            check(initial.map { $0.isAccessibilitySelected() } == [false, false], "no row starts selected")
            check(!initial[0].isAccessibilityDisclosed(), "a collapsed directory reports not expanded")
            check(initial[0].isAccessibilityEnabled(), "a directory is enabled through its expand path")
            check(!initial[1].isAccessibilityEnabled(), "a file without onSelect is disabled")
            check(!initial[1].accessibilityPerformPress(), "a disabled file refuses AXPress")
        }

        print("=== press uses the production select and expand paths ===")
        var selectedPaths: [RepositoryPath] = []
        rows.onSelect = {
            selectedPaths.append($0)
            return true
        }
        check(children(of: rows).first === initial.first, "changing availability preserves row identity")
        if initial.count == 2 {
            check(initial[1].isAccessibilityEnabled(), "installing onSelect enables a file")
            check(initial[1].accessibilityPerformPress(), "an enabled file accepts AXPress")
            check(selectedPaths == [RepositoryPath("README.md")], "AXPress sends the exact RepositoryPath through onSelect")
            check(initial[1].isAccessibilitySelected(), "the pressed file reports selected")
            let selected = rows.accessibilitySelectedRows() as? [NSAccessibilityElement] ?? []
            check(selected.count == 1 && selected[0] === initial[1], "the outline selected-rows attribute follows AXPress")

            check(initial[0].accessibilityPerformPress(), "a directory accepts AXPress")
            check(initial[0].isAccessibilityDisclosed(), "directory AXPress reports the expanded state")
            check(initial[0].isAccessibilitySelected(), "the pressed directory reports selected")
        }

        let expanded = children(of: rows)
        check(expanded.count == 3, "expanding exposes the nested row")
        check(expanded.first === initial.first, "expansion preserves the directory element identity")
        if expanded.count == 3 {
            check(expanded.map { $0.accessibilityIndex() } == [0, 1, 2], "expanded rows expose their current flattened indices")
            check(expanded[1].accessibilityLabel() == "main.swift", "the nested filename is exposed")
            check(expanded[1].accessibilityValue() as? String == "Sources/main.swift", "the nested full path is exposed")
            check(expanded[1].accessibilityDisclosureLevel() == 1, "the nested row exposes hierarchy level one")
            check(expanded[1].accessibilityDisclosedByRow() as? NSAccessibilityElement === expanded[0], "the nested row names its directory parent")
            let disclosed = expanded[0].accessibilityDisclosedRows() as? [NSAccessibilityElement] ?? []
            check(disclosed.count == 1 && disclosed[0] === expanded[1], "the directory exposes its direct disclosed rows")
        }

        print("=== actions preserve path bytes ===")
        let rawName = RepositoryPath([0x66, 0x80])
        let rawPath = RepositoryPath([0x64, 0x69, 0x72, 0x2f, 0x66, 0x80])
        rows.tree = [FileTreeNode(name: rawName, path: rawPath, isDirectory: false, children: [])]
        var byteSelections: [RepositoryPath] = []
        rows.onSelect = {
            byteSelections.append($0)
            return true
        }
        let byteRows = children(of: rows)
        if let byteRow = byteRows.first {
            check(byteRow.accessibilityLabel() == rawName.display, "the filename has the documented lossy display spelling")
            check(byteRow.accessibilityValue() as? String == rawPath.display, "the full path has the documented lossy display spelling")
            check(byteRow.accessibilityPerformPress(), "the byte-path row accepts AXPress")
            check(byteSelections.first?.bytes == rawPath.bytes, "AXPress preserves every RepositoryPath byte")
        } else {
            check(false, "the byte-path tree exposes its semantic row")
        }

        print("=== offscreen, obsolete, and reentrant rows ===")
        rows.onSelect = {
            selectedPaths.append($0)
            return true
        }
        rows.tree = (0 ..< 20).map { node("file-\($0).swift") }
        let allRows = children(of: rows)
        check(allRows.count == 20, "every result remains reachable in the semantic outline")
        check(visibleChildren(of: rows).count < allRows.count, "visible children remain a viewport subset")
        check(
            (rows.accessibilityVisibleRows() as? [NSAccessibilityElement])?.count == visibleChildren(of: rows).count,
            "the outline visible-rows attribute follows the viewport"
        )
        if let last = allRows.last {
            check(last.accessibilityPerformPress(), "an offscreen semantic row accepts AXPress")
            check(selectedPaths.last == RepositoryPath("file-19.swift"), "the offscreen row sends its own path")
            check(last.isAccessibilitySelected(), "the offscreen pressed row reports selected")
        }

        if allRows.count == 20 {
            let rootARow = allRows[3]
            rows.anchorPath = "/repositories/B"
            rows.tree = (0 ..< 20).map { node("file-\($0).swift") }
            check(!rootARow.accessibilityPerformPress(), "a retained row refuses after the repository root changes")
            check(selectedPaths.count == 2, "the obsolete root row calls no selection closure")

            let currentRows = children(of: rows)
            if currentRows.count == 20 {
                let beforeReplacement = currentRows[4]
                rows.onSelect = { path in
                    selectedPaths.append(path)
                    rows.tree = [node("replacement.swift")]
                    return true
                }
                check(beforeReplacement.accessibilityPerformPress(), "the in-flight old row completes its existing selection closure")
                check(selectedPaths.last == RepositoryPath("file-4.swift"), "reentrant replacement cannot change the path sent")
                let replacement = children(of: rows)
                check(replacement.count == 1 && replacement[0].accessibilityLabel() == "replacement.swift", "the replacement result becomes the only child")
                check(replacement.first?.isAccessibilitySelected() == false, "reentrant replacement cannot retarget semantic selection")
                check(!beforeReplacement.accessibilityPerformPress(), "the retained pre-replacement row becomes obsolete")
                check(selectedPaths.count == 3, "the obsolete result calls no closure")
            } else {
                check(false, "root replacement keeps twenty fresh semantic rows")
            }
        } else {
            check(false, "obsolete and reentrant checks have semantic rows to retain")
        }

        print("=== large outline traversal stays near linear ===")
        let smallTraversal = medianOutlineTraversal(childCount: 250, passes: 3)
        let largeTraversal = medianOutlineTraversal(childCount: 1_000, passes: 3)
        let traversalRatio = Double(largeTraversal.elapsedNanoseconds)
            / Double(max(1, smallTraversal.elapsedNanoseconds))
        print(
            "  measurement 251 rows: \(smallTraversal.elapsedNanoseconds) ns; "
                + "1001 rows: \(largeTraversal.elapsedNanoseconds) ns; ratio: "
                + String(format: "%.2f", traversalRatio)
        )
        check(
            smallTraversal.checksum > 0 && largeTraversal.checksum > smallTraversal.checksum,
            "the bound walks real row properties and disclosure relationships"
        )
        check(
            traversalRatio < 10,
            "four times as many rows takes less than ten times as long"
        )

        check(rows.window == nil && scroll.window == nil, "all accessibility checks remain windowless")
        print(failures == 0 ? "PASS" : "FAILED \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
