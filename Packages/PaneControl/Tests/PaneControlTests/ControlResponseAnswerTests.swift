import Testing

@testable import PaneControl

/// The two formatters that turn what the mailbox and the ring hand back into
/// what goes on the wire. Thin enough that the tempting review note is "there is
/// nothing to test here"; the thing being pinned is which fields survive, and a
/// field silently dropped is a caller that never learns it lost messages.
@Suite struct ControlResponseAnswerTests {
    @Test func aDrainCarriesItsMessagesAndBothCounts() {
        let drain = Drain(
            messages: [ControlMessage(from: "c1", text: "one")],
            more: true,
            dropped: 3
        )

        let response = ControlResponse.answer(for: drain)

        #expect(response.ok)
        #expect(response.error == nil)
        #expect(response.result?.messages == drain.messages)
        #expect(response.result?.more == true)
        #expect(response.result?.dropped == 3)
    }

    /// Nothing to deliver is a success with an empty list, not a failure and not
    /// a response with no body: a parked `recv` resolved at app terminate is
    /// answered this way, and a client that got an error there would report a
    /// broken channel for an orderly shutdown.
    @Test func anEmptyDrainIsASuccessAndNotAnError() {
        let response = ControlResponse.answer(for: Drain.empty)

        #expect(response.ok)
        #expect(response.error == nil)
        #expect(response.result?.messages == [])
        #expect(response.result?.more == false)
        #expect(response.result?.dropped == 0)
    }

    /// The count that says what was lost survives an otherwise empty answer.
    /// `dropped` folded into `messages.isEmpty` would make an overflowing mailbox
    /// indistinguishable from an idle one.
    @Test func dropsAreReportedEvenWhenNothingIsDelivered() {
        let response = ControlResponse.answer(
            for: Drain(messages: [], more: false, dropped: 12)
        )

        #expect(response.result?.dropped == 12)
        #expect(response.result?.messages == [])
    }

    /// A `recv` answer names no pane and carries no layout. The result type is
    /// the union of every verb's answer, so a formatter that filled a field it
    /// had no business filling would put another verb's shape on this wire.
    @Test func aDrainAnswerFillsNothingBelongingToAnotherVerb() {
        let response = ControlResponse.answer(
            for: Drain(messages: [ControlMessage(from: "c1", text: "one")], more: false, dropped: 0)
        )

        #expect(response.result?.pane == nil)
        #expect(response.result?.panes == nil)
        #expect(response.result?.events == nil)
        #expect(response.result?.seq == nil)
        #expect(response.result?.gap == nil)
        #expect(response.result?.rendezvous == nil)
        #expect(response.result?.layout == nil)
    }
}
