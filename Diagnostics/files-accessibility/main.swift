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

/// The single cell VoiceOver's table mode lands on under a semantic row, or nil
/// when the row is a leaf.
func cell(of row: NSAccessibilityElement) -> NSAccessibilityElement? {
    let children = row.accessibilityChildren() as? [NSAccessibilityElement] ?? []
    return children.first { $0.accessibilityRole() == .cell }
}

@MainActor
func elements(_ value: Any?) -> [NSAccessibilityElement] {
    value as? [NSAccessibilityElement] ?? []
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
        // VoiceOver navigates AXTable and AXOutline in table mode: the cursor
        // lands on cells, never on a bare row. A leaf row inside a table-family
        // container is reachable over the AX API and unreachable by VoiceOver
        // (native capture 2026-09-10: "Files, table, No selection." and no cursor
        // move entered the row). The palette's AXList is navigated by children
        // and is allowed to keep leaf rows.
        let tableFamily: Set<NSAccessibility.Role> = [.table, .outline]
        if let role = rows.accessibilityRole(), tableFamily.contains(role) {
            check(
                !initial.isEmpty && initial.allSatisfy { cell(of: $0) != nil },
                "a table-family container gives every row a cell child, which VoiceOver's table mode lands on"
            )
        } else {
            check(rows.accessibilityRole() == .list, "a leaf-row container is a list, which VoiceOver navigates by children")
        }
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
            check(initial.allSatisfy { $0.accessibilitySubrole() == .outlineRow }, "every row carries the outline-row subrole")
            check(
                initial.allSatisfy { ($0.accessibilityChildren() as? [NSAccessibilityElement])?.count == 1 },
                "every row has exactly one child, its cell"
            )
            let cells = initial.compactMap(cell(of:))
            check(cells.count == 2, "every row exposes its cell")
            if cells.count == 2 {
                check(cells.map { $0.accessibilityParent() as? NSAccessibilityElement } .elementsEqual(initial, by: { $0 === $1 }), "every cell names its row as parent")
                check(cells.map { $0.accessibilityLabel() ?? "" } == ["Sources/", "README.md"], "every cell speaks the row's filename")
                check(cells.map { $0.accessibilityValue() as? String ?? "" } == ["Sources", "README.md"], "every cell exposes the row's full path")
                check(zip(cells, initial).allSatisfy { $0.accessibilityFrame() == $1.accessibilityFrame() }, "every cell covers exactly its row's frame")
                check(cells.allSatisfy { actionNames(of: $0).contains(.press) }, "every cell exposes AXPress")
                check(cells.map { $0.isAccessibilityEnabled() } == [true, false], "every cell reports its row's enabled state")
                check(cells.map { $0.isAccessibilitySelected() } == [false, false], "no cell starts selected")
                check(!cells[1].accessibilityPerformPress(), "a disabled file's cell refuses AXPress")
                check(cells.map { $0.accessibilityRowIndexRange() } == [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1)], "every cell exposes its row index range")
                check(cells.allSatisfy { $0.accessibilityColumnIndexRange() == NSRange(location: 0, length: 1) }, "every cell sits in the single column")
                check(elements(rows.accessibilitySelectedCells()).isEmpty, "the outline selected-cells attribute starts empty")
                check(elements(rows.accessibilityVisibleCells()).elementsEqual(cells, by: { $0 === $1 }), "the outline visible-cells attribute lists the visible rows' cells in order")
            }
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

            let selectedCells = elements(rows.accessibilitySelectedCells())
            check(selectedCells.count == 1 && selectedCells[0] === cell(of: initial[1]), "the outline selected-cells attribute follows the pressed row's cell")
            check(cell(of: initial[1])?.isAccessibilitySelected() == true, "the pressed file's cell reports selected")

            let beforeDirectoryPress = selectedPaths.count
            check(cell(of: initial[0])?.accessibilityPerformPress() == true, "a directory cell accepts AXPress")
            check(selectedPaths.count == beforeDirectoryPress, "a directory cell expands without inserting its path")
            check(initial[0].isAccessibilityDisclosed(), "directory AXPress reports the expanded state")
            check(initial[0].isAccessibilitySelected(), "the pressed directory reports selected")
            check(cell(of: initial[1])?.isAccessibilitySelected() == false, "selection moving to the directory deselects the file's cell")
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
            check(cell(of: expanded[0]) != nil && cell(of: expanded[0]) === cell(of: initial[0]), "expansion preserves the cell element identity")
            check(cell(of: expanded[1])?.accessibilityRowIndexRange() == NSRange(location: 1, length: 1), "the nested cell exposes its current row index")
            check(cell(of: expanded[1])?.accessibilityPerformPress() == true, "AXPress on the nested cell selects through the row's path")
            check(selectedPaths.last == RepositoryPath("Sources/main.swift"), "the cell sends the exact RepositoryPath through onSelect")
            check(expanded[1].isAccessibilitySelected(), "a cell press selects its row")
            let selectedRows = elements(rows.accessibilitySelectedRows())
            check(selectedRows.count == 1 && selectedRows[0] === expanded[1], "the outline selected-rows attribute follows a cell press")
            let beforeTopLevelPress = selectedPaths.count
            check(cell(of: expanded[2])?.accessibilityPerformPress() == true, "AXPress on a top-level cell selects through the row's path")
            check(selectedPaths.count == beforeTopLevelPress + 1 && selectedPaths.last == RepositoryPath("README.md"), "the top-level cell sends its own path exactly once")
            check(cell(of: expanded[2])?.accessibilityPerformPress() == true, "a second AXPress on the selected cell still reaches onSelect")
            check(selectedPaths.count == 4, "each cell press sends exactly one selection")
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
            check(cell(of: byteRow)?.accessibilityLabel() == rawName.display, "the cell has the same lossy display spelling as its row")
            check(cell(of: byteRow)?.accessibilityPerformPress() == true, "the byte-path cell accepts AXPress")
            check(byteSelections.count == 2 && byteSelections.last?.bytes == rawPath.bytes, "a cell press preserves every RepositoryPath byte")
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
        check(
            elements(rows.accessibilityVisibleCells()).count == visibleChildren(of: rows).count,
            "the outline visible-cells attribute follows the viewport"
        )
        if let last = allRows.last {
            check(last.accessibilityPerformPress(), "an offscreen semantic row accepts AXPress")
            check(selectedPaths.last == RepositoryPath("file-19.swift"), "the offscreen row sends its own path")
            check(last.isAccessibilitySelected(), "the offscreen pressed row reports selected")
            check(cell(of: last)?.accessibilityFrame() == last.accessibilityFrame(), "an offscreen cell keeps its row's frame")
        }

        if allRows.count == 20 {
            let rootARow = allRows[3]
            let rootACell = cell(of: rootARow)
            let pressesBeforeRootChange = selectedPaths.count
            rows.anchorPath = "/repositories/B"
            rows.tree = (0 ..< 20).map { node("file-\($0).swift") }
            check(!rootARow.accessibilityPerformPress(), "a retained row refuses after the repository root changes")
            check(selectedPaths.count == pressesBeforeRootChange, "the obsolete root row calls no selection closure")
            check(rootACell != nil && rootACell?.accessibilityPerformPress() == false, "a retained cell refuses after the repository root changes")
            check(rootACell?.accessibilityLabel() == nil && rootACell?.isAccessibilityEnabled() == false, "a stale cell has no label and is disabled")
            check(rootACell?.accessibilityFrame() == .zero && rootACell?.accessibilityRowIndexRange().location == NSNotFound, "a stale cell has no frame and no row index")
            check(selectedPaths.count == pressesBeforeRootChange, "the obsolete cell calls no selection closure")
            check(cell(of: children(of: rows)[3]) !== rootACell, "the replacement root builds a fresh cell for the same relative path")

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
                check(cell(of: beforeReplacement)?.accessibilityPerformPress() == false, "the retained pre-replacement cell becomes obsolete")
                check(selectedPaths.count == pressesBeforeRootChange + 1, "the obsolete result calls no closure")
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
