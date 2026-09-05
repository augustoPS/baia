import AppKit
import PaneChrome

var failures = 0

func check(_ passed: Bool, _ message: String) {
    if passed {
        print("  ok    \(message)")
    } else {
        failures += 1
        print("  FAIL  \(message)")
    }
}

func accessibilityActionNames(of element: NSAccessibilityElement) -> [NSAccessibility.Action] {
    let selector = NSSelectorFromString("accessibilityActionNames")
    guard element.responds(to: selector),
          let value = element.perform(selector)?.takeUnretainedValue()
    else { return [] }
    return value as? [NSAccessibility.Action] ?? []
}

@MainActor
func children(of list: PaletteListView) -> [NSAccessibilityElement] {
    (list.accessibilityChildren() as? [NSAccessibilityElement]) ?? []
}

@MainActor
func visibleChildren(of list: PaletteListView) -> [NSAccessibilityElement] {
    (list.accessibilityVisibleChildren() as? [NSAccessibilityElement]) ?? []
}

@MainActor
func rowsAttribute(of list: PaletteListView) -> [NSAccessibilityElement] {
    (list.accessibilityRows() as? [NSAccessibilityElement]) ?? []
}

@MainActor
func visibleRowsAttribute(of list: PaletteListView) -> [NSAccessibilityElement] {
    (list.accessibilityVisibleRows() as? [NSAccessibilityElement]) ?? []
}

@MainActor
func selectedChildren(of list: PaletteListView) -> [NSAccessibilityElement] {
    (list.accessibilitySelectedChildren() as? [NSAccessibilityElement]) ?? []
}

@MainActor
func selectedRows(of list: PaletteListView) -> [NSAccessibilityElement] {
    (list.accessibilitySelectedRows() as? [NSAccessibilityElement]) ?? []
}

/// Records what the list actually delivers while replacing `rows`, then forwards
/// to the list's own delivery so the default remains `NSAccessibility.post`.
@MainActor
func notificationsPosted(
    by list: PaletteListView,
    replacingRowsWith rows: [PaletteRow]
) -> [NSAccessibility.Notification] {
    var posted: [NSAccessibility.Notification] = []
    let deliver = list.postAccessibilityNotification
    list.postAccessibilityNotification = { element, notification in
        if element === list { posted.append(notification) }
        deliver(element, notification)
    }
    list.rows = rows
    list.postAccessibilityNotification = deliver
    return posted
}

@main
enum PaletteAccessibilityFixture {
    @MainActor static func main() {
        let list = PaletteListView(frame: NSRect(x: 0, y: 0, width: 480, height: 224))
        let project = PaletteRow.make(relativePath: "website/shop", matchedIndices: [8, 9])
        let unavailable = PaletteRow.verb(
            title: "Close Pane",
            matchedIndices: [0],
            unavailableReason: "needs a pane"
        )
        let command = PaletteRow.verb(title: "New Window", matchedIndices: [0, 4])
        list.rows = [project, unavailable, command]
        list.selection = 0

        print("=== production list semantics ===")
        check(list.window == nil, "the fixture creates no window")
        check(!list.acceptsFirstResponder, "the drawn list still refuses first responder")
        check(list.isAccessibilityElement(), "the list is an accessibility element")
        check(list.accessibilityRole() == .list, "the container role is list")
        check(list.accessibilityLabel() == "Results", "the list role has its required stable label")

        let initial = children(of: list)
        check(initial.count == 3, "one accessibility child exists per visible row")
        let initialRows = rowsAttribute(of: list)
        check(
            initialRows.count == initial.count
                && zip(initialRows, initial).allSatisfy { $0.0 === $0.1 },
            "the required rows attribute exposes the cached semantic children"
        )
        let initialVisibleRows = visibleRowsAttribute(of: list)
        let initialVisibleChildren = visibleChildren(of: list)
        check(
            initialVisibleRows.count == initialVisibleChildren.count
                && zip(initialVisibleRows, initialVisibleChildren).allSatisfy { $0.0 === $0.1 },
            "the visible-rows attribute exposes the cached visible children"
        )
        let initiallySelectedChildren = selectedChildren(of: list)
        let initiallySelectedRows = selectedRows(of: list)
        check(
            initiallySelectedChildren.count == 1 && initiallySelectedChildren.first === initial.first,
            "the selected-children attribute exposes the cached selected child"
        )
        check(
            initiallySelectedRows.count == 1 && initiallySelectedRows.first === initial.first,
            "the selected-rows attribute exposes the cached selected child"
        )
        if initial.count == 3 {
            check(initial.allSatisfy { $0.accessibilityRole() == .row }, "every child role is row")
            check(initial.map { $0.accessibilityIndex() } == [0, 1, 2], "every row exposes its required index")
            check(
                initial.allSatisfy { accessibilityActionNames(of: $0).contains(.press) },
                "every row exposes AXPress"
            )
            check(
                initial.map { $0.accessibilityLabel() ?? "" }
                    == ["website/shop", "Close Pane  needs a pane", "New Window"],
                "labels are the exact drawn row strings"
            )
            check(initial.map { $0.isAccessibilitySelected() } == [true, false, false], "selected state follows the list")
            check(initial.map { $0.isAccessibilityEnabled() } == [true, false, true], "enabled state follows row availability")
        }

        print("=== press uses the existing activation path ===")
        var activations: [(Int, PaletteAction)] = []
        list.onActivate = { activations.append(($0, $1)) }
        if initial.count == 3 {
            check(initial[2].accessibilityPerformPress(), "an enabled row accepts AXPress")
            check(list.selection == 2, "AXPress selects the pressed row")
            check(activations.count == 1, "AXPress calls the list activation closure once")
            if let activation = activations.first {
                check(activation.0 == 2 && activation.1 == .newTab, "AXPress uses the plain Return action")
            }
            check(initial.map { $0.isAccessibilitySelected() } == [false, false, true], "existing children report the new selection")
            check(selectedChildren(of: list).first === initial[2], "selected children follow AXPress")
            check(selectedRows(of: list).first === initial[2], "selected rows follow AXPress")

            check(!initial[1].accessibilityPerformPress(), "a disabled row refuses AXPress")
            check(activations.count == 1, "a disabled row calls no activation closure")
        }

        print("=== reentrant selection cannot retarget a press ===")
        let reentrant = PaletteListView(frame: list.frame)
        reentrant.rows = (0 ..< 3).map { PaletteRow.make(relativePath: "before-\($0)") }
        let pressedBeforeReplacement = children(of: reentrant)[2]
        var reentrantActivations = 0
        reentrant.onSelectionChange = {
            reentrant.rows = [PaletteRow.make(relativePath: "replacement")]
        }
        reentrant.onActivate = { _, _ in reentrantActivations += 1 }
        check(
            !pressedBeforeReplacement.accessibilityPerformPress(),
            "a selection callback replacing rows makes the in-flight press obsolete"
        )
        check(reentrantActivations == 0, "reentrant replacement calls no activation closure")

        print("=== visible and obsolete children ===")
        let stale = initial.first
        list.rows = (0 ..< 9).map { PaletteRow.make(relativePath: "project-\($0)") }
        let allRows = children(of: list)
        check(allRows.count == 9, "every result stays reachable through the semantic list")
        check(
            rowsAttribute(of: list).count == allRows.count
                && zip(rowsAttribute(of: list), allRows).allSatisfy { $0.0 === $0.1 },
            "the rows attribute keeps the semantic child identities after replacement"
        )
        check(visibleChildren(of: list).count == 8, "the visible subset contains eight rows")
        check(allRows[8].accessibilityPerformPress(), "an offscreen semantic row accepts AXPress")
        check(list.selection == 8, "pressing an offscreen row scrolls it into view")
        let scrolled = visibleChildren(of: list)
        let scrolledRows = visibleRowsAttribute(of: list)
        check(scrolled.first?.accessibilityLabel() == "project-1", "the visible subset follows scrolling")
        check(scrolled.last?.isAccessibilitySelected() == true, "the selected visible child reports selected")
        check(
            scrolledRows.count == scrolled.count
                && zip(scrolledRows, scrolled).allSatisfy { $0.0 === $0.1 },
            "the visible-rows attribute follows internal scrolling"
        )
        check(
            children(of: list).first === allRows.first,
            "scrolling preserves semantic row identity"
        )
        if let stale {
            check(stale.accessibilityIndex() == NSNotFound, "a replaced child refuses its obsolete index")
            check(!stale.accessibilityPerformPress(), "a child from a replaced result set refuses AXPress")
            check(activations.count == 2, "an obsolete child calls no activation closure")
        }

        print("=== result replacement notifies assistive clients ===")
        let notifying = PaletteListView(frame: list.frame)
        notifying.rows = (0 ..< 3).map { PaletteRow.make(relativePath: "seed-\($0)") }
        notifying.selection = 0
        let seedChildren = children(of: notifying)
        check(!notifying.acceptsFirstResponder, "replacement setup still refuses first responder")

        let sameCount = notificationsPosted(
            by: notifying,
            replacingRowsWith: (0 ..< 3).map { PaletteRow.make(relativePath: "same-\($0)") }
        )
        check(
            sameCount.contains(.layoutChanged),
            "same-count replacement posts layoutChanged"
        )
        check(
            sameCount.contains(.selectedRowsChanged),
            "same-count replacement at a valid selection posts selectedRowsChanged"
        )
        check(
            !sameCount.contains(.rowCountChanged),
            "same-count replacement does not post rowCountChanged"
        )
        check(
            !sameCount.contains(.announcementRequested),
            "same-count replacement does not post a speech announcement"
        )
        check(
            seedChildren.first.map { !$0.accessibilityPerformPress() } ?? false,
            "same-count replacement still makes the previous children obsolete"
        )
        check(!notifying.acceptsFirstResponder, "same-count replacement does not take first responder")

        let grown = notificationsPosted(
            by: notifying,
            replacingRowsWith: (0 ..< 9).map { PaletteRow.make(relativePath: "grown-\($0)") }
        )
        check(grown.contains(.layoutChanged), "a longer result set posts layoutChanged")
        check(grown.contains(.rowCountChanged), "a longer result set posts rowCountChanged")
        check(
            grown.contains(.selectedRowsChanged),
            "a longer result set at the same valid selection posts selectedRowsChanged"
        )
        check(
            !grown.contains(.announcementRequested),
            "a longer result set does not post a speech announcement"
        )

        let emptied = notificationsPosted(
            by: notifying,
            replacingRowsWith: []
        )
        check(emptied.contains(.layoutChanged), "empty results post layoutChanged")
        check(emptied.contains(.rowCountChanged), "empty results post rowCountChanged")
        check(
            !emptied.contains(.selectedRowsChanged),
            "empty results do not post selectedRowsChanged for an invalid selection"
        )
        check(
            !emptied.contains(.announcementRequested),
            "empty results do not post a speech announcement"
        )
        check(children(of: notifying).isEmpty, "empty results expose no semantic children")
        check(rowsAttribute(of: notifying).isEmpty, "empty results expose an empty rows attribute")
        check(visibleRowsAttribute(of: notifying).isEmpty, "empty results expose no visible rows")
        check(selectedChildren(of: notifying).isEmpty, "empty results expose no selected children")
        check(selectedRows(of: notifying).isEmpty, "empty results expose no selected rows")
        check(!notifying.acceptsFirstResponder, "empty results still refuse first responder")
        check(notifying.window == nil, "notification checks created no window or focus target")

        check(list.window == nil, "accessibility checks created no window or focus target")
        print(failures == 0 ? "PASS" : "FAILED \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
