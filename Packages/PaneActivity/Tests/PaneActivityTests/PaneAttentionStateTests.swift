import Foundation
import Testing

@testable import PaneActivity

/// Every mutation lands in a `let` before it is expected on, rather than inside
/// the `#expect`. The macro rewrites a call it is handed directly into a
/// closure over an immutable copy, so `#expect(state.noteBell())` does not
/// compile for a mutating method at all.
@Suite struct PaneAttentionStateTests {
    @Test func aFreshPaneWantsNothing() {
        #expect(PaneAttentionState().attention == PaneAttention.none)
    }

    @Test func aBellRequestsAttentionWithNoMessage() {
        var state = PaneAttentionState()
        let changed = state.noteBell()
        #expect(changed)
        #expect(state.attention == .requested(message: nil))
    }

    @Test func aSecondBellWhileAlreadyRequestingIsNotAChange() {
        // The whole reason `noteBell` returns a Bool. A program at a prompt
        // rings on every rejected keystroke, and a caller that redrew on each
        // one would flash the indicator rather than leave it lit.
        var state = PaneAttentionState()
        let first = state.noteBell()
        let second = state.noteBell()
        #expect(first)
        #expect(!second)
        #expect(state.attention == .requested(message: nil))
    }

    @Test func aNotificationCarriesItsTitleAndBodyAsOneLine() {
        var state = PaneAttentionState()
        let changed = state.noteNotification(title: "baia", body: "Ready for input")
        #expect(changed)
        #expect(state.attention == .requested(message: "baia: Ready for input"))
    }

    @Test func anOscNineNotificationWithNoTitleIsJustItsBody() {
        // OSC 9 has no title field, so this is the shape the common case
        // arrives in. Joining unconditionally would prefix every such message
        // with ": ".
        var state = PaneAttentionState()
        let changed = state.noteNotification(title: "", body: "Ready for input")
        #expect(changed)
        #expect(state.attention == .requested(message: "Ready for input"))
    }

    @Test func aNotificationWithNoBodyIsJustItsTitle() {
        var state = PaneAttentionState()
        let changed = state.noteNotification(title: "baia", body: "")
        #expect(changed)
        #expect(state.attention == .requested(message: "baia"))
    }

    @Test func anEmptyNotificationPayloadReadsAsABareBell() {
        // Whitespace only, which is what a program emitting OSC 9 with nothing
        // to say produces. Keeping it would hang an empty tooltip off the
        // indicator, and it carries no more than a bell does.
        var state = PaneAttentionState()
        let changed = state.noteNotification(title: "  ", body: "\n")
        #expect(changed)
        #expect(state.attention == .requested(message: nil))
    }

    @Test func aBareBellDoesNotEraseAMessageThatArrivedFirst() {
        // Claude Code's `iterm2_with_bell` channel emits OSC 9 and a bell for
        // one request, in that order. Letting the bell win would throw away the
        // repository name, which is the only part that tells five panes apart.
        var state = PaneAttentionState()
        let notified = state.noteNotification(title: "baia", body: "Ready")
        let rang = state.noteBell()
        #expect(notified)
        #expect(!rang)
        #expect(state.attention == .requested(message: "baia: Ready"))
    }

    @Test func aNotificationUpgradesAnEarlierBell() {
        // The other order of the same pair, which is not symmetrical: a message
        // arriving after a bell is new information and has to report a change
        // so the caller redraws with the text.
        var state = PaneAttentionState()
        let rang = state.noteBell()
        let notified = state.noteNotification(title: "baia", body: "Ready")
        #expect(rang)
        #expect(notified)
        #expect(state.attention == .requested(message: "baia: Ready"))
    }

    @Test func repeatingTheSameNotificationIsNotAChange() {
        var state = PaneAttentionState()
        let first = state.noteNotification(title: "baia", body: "Ready")
        let second = state.noteNotification(title: "baia", body: "Ready")
        #expect(first)
        #expect(!second)
    }

    @Test func aDifferentNotificationIsAChange() {
        // The mirror of the repeat above. Comparing only against `.none` would
        // make both cases quiet, and the pane would keep showing the first
        // message a session ever sent.
        var state = PaneAttentionState()
        let first = state.noteNotification(title: "baia", body: "Ready")
        let second = state.noteNotification(title: "baia", body: "Permission needed")
        #expect(first)
        #expect(second)
        #expect(state.attention == .requested(message: "baia: Permission needed"))
    }

    @Test func focusingAcknowledgesWithoutEndingTheRequest() {
        // This used to drop straight to `.none`, and that was the bug the two
        // levels fix. A pane the owner glanced at is still waiting for him, so
        // clearing the marker on sight made it indistinguishable from one that
        // had gone back to work, which is the exact confusion the marker exists
        // to remove.
        var state = PaneAttentionState()
        let rang = state.noteBell()
        let seen = state.noteFocused()
        #expect(rang)
        #expect(seen)
        #expect(state.attention == .acknowledged(message: nil))
        #expect(state.attention.isRequesting)
        #expect(!state.attention.isUnacknowledged)
    }

    @Test func onlyThePaneGoingBackToWorkEndsTheRequest() {
        // The one thing that ends it, and it is about the pane rather than about
        // who looked at it.
        var state = PaneAttentionState()
        _ = state.noteBell()
        _ = state.noteFocused()
        let resumed = state.noteResumed()
        #expect(resumed)
        #expect(state.attention == PaneAttention.none)
    }

    @Test func aPaneThatWasNeverAskingHasNothingToResumeFrom() {
        // Reported as no change, because the activity poll calls this on every
        // idle-to-running transition and a redraw per transition would repaint
        // every pane's chrome for nothing.
        var state = PaneAttentionState()
        let resumed = state.noteResumed()
        #expect(!resumed)
        #expect(state.attention == PaneAttention.none)
    }

    @Test func anAcknowledgedRequestKeepsTheMessageThatNamedIt() {
        // The message says which repository asked. Losing it on acknowledgement
        // would leave the quiet level saying only that something, somewhere, is
        // still waiting.
        var state = PaneAttentionState()
        _ = state.noteNotification(title: "vault", body: "Permission needed")
        _ = state.noteFocused()
        #expect(state.attention.message == "vault: Permission needed")
    }

    @Test func focusingAPaneThatWantsNothingIsNotAChange() {
        // Focus changes arrive on every window switch, not only on the ones
        // that acknowledge something. Reporting a change here would redraw
        // every pane's indicator on every click.
        var state = PaneAttentionState()
        let cleared = state.noteFocused()
        #expect(!cleared)
        #expect(state.attention == PaneAttention.none)
    }

    @Test func aBellAfterFocusingRequestsAgain() {
        // Acknowledging has to leave the state usable rather than latched. An
        // agent that finishes twice in one session must light the indicator
        // twice, and the acknowledgement it earned the first time was for the
        // first request.
        var state = PaneAttentionState()
        let first = state.noteBell()
        let seen = state.noteFocused()
        let again = state.noteBell()
        #expect(first)
        #expect(seen)
        #expect(again)
        #expect(state.attention == .requested(message: nil))
        #expect(state.attention.isUnacknowledged)
    }

    @Test func twoPanesTrackTheirAttentionSeparately() {
        // The type is a value, so an app layer holding one per pane cannot leak
        // one pane's state into another. A reference type here would have lit
        // the indicator on whichever pane was drawn last.
        let quiet = PaneAttentionState()
        var noisy = PaneAttentionState()
        let rang = noisy.noteBell()
        #expect(rang)
        #expect(quiet.attention == PaneAttention.none)
        #expect(quiet != noisy)
    }
}
