import Foundation
import Testing

@testable import PaneChrome

@Suite struct ApprovalPopoverTests {
    @Test func presentsOnlyWhileAskingOrAcknowledged() {
        // The capsule itself draws for exactly these two levels
        // (`PaneStatusBarView.capsuleRect()`); a done pane shows a bare ✓, a
        // fact rather than a question, and a click on it must open nothing.
        #expect(ApprovalPopover.presents(for: .asking))
        #expect(ApprovalPopover.presents(for: .acknowledged))
        #expect(!ApprovalPopover.presents(for: .done))
        #expect(!ApprovalPopover.presents(for: .none))
    }

    @Test func approveWritesCarriageReturn() {
        #expect(ApprovalPopover.bytes(for: .approve) == [0x0D])
    }

    @Test func denyWritesEscape() {
        #expect(ApprovalPopover.bytes(for: .deny) == [0x1B])
    }

    @Test func eachActionWritesExactlyOneByte() {
        // "One keystroke per press, nothing else on the wire" is the acceptance
        // criterion the plan states in those words. A regression that grew
        // either case into a line of text would still compile and still read
        // as "approve" or "deny" from the call site, so the length is asserted
        // on its own rather than folded into the value checks above.
        for action in ApprovalPopover.Action.allCases {
            #expect(ApprovalPopover.bytes(for: action).count == 1)
        }
    }

    @Test func bodyIsTheMessageVerbatim() {
        #expect(ApprovalPopover.body(for: "Run the migration?") == "Run the migration?")
    }

    @Test func bodyFallsBackForABareBell() {
        #expect(ApprovalPopover.body(for: nil) == "Waiting for input")
    }

    @Test func bodyFallsBackForAWhitespaceOnlyMessage() {
        // A message the caller trims to nothing still means "no statement was
        // made", the same as nil, so it takes the same fallback rather than
        // showing the owner an empty body.
        #expect(ApprovalPopover.body(for: "   \n") == "Waiting for input")
    }

    @Test func bodyTrimsSurroundingWhitespace() {
        #expect(ApprovalPopover.body(for: "  needs a decision  ") == "needs a decision")
    }
}
