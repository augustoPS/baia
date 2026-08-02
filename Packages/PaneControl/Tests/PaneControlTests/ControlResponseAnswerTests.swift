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

    @Test func aBatchCarriesItsEventsTheCursorAndBothFlags() {
        let batch = EventBatch(
            events: [ControlEvent(seq: 7, kind: .paneOpened, pane: "p")],
            more: true,
            gap: true,
            seq: 7
        )

        let response = ControlResponse.answer(for: batch)

        #expect(response.ok)
        #expect(response.error == nil)
        #expect(response.result?.events == batch.events)
        #expect(response.result?.more == true)
        #expect(response.result?.gap == true)
        #expect(response.result?.seq == 7)
    }

    /// The cursor goes out even with nothing behind it. `subscribe` hands `seq`
    /// back on the next call, so an empty batch that omitted it would make the
    /// client resume from whatever it last remembered and re-read the window it
    /// already had.
    @Test func anEmptyBatchStillCarriesTheCursorItWasTakenAt() {
        let response = ControlResponse.answer(for: EventBatch.empty(at: 42))

        #expect(response.ok)
        #expect(response.result?.seq == 42)
        #expect(response.result?.events == [])
        #expect(response.result?.more == false)
        #expect(response.result?.gap == false)
    }

    /// `gap` is a separate fact from `more`. `more` says the ring has further
    /// events after this batch; `gap` says it overwrote events before it. A
    /// caller told only `more` would read a lossy stream as a complete one.
    @Test func gapAndMoreAreCarriedIndependently() {
        let gapOnly = ControlResponse.answer(
            for: EventBatch(events: [], more: false, gap: true, seq: 3)
        )
        #expect(gapOnly.result?.gap == true)
        #expect(gapOnly.result?.more == false)

        let moreOnly = ControlResponse.answer(
            for: EventBatch(events: [], more: true, gap: false, seq: 3)
        )
        #expect(moreOnly.result?.gap == false)
        #expect(moreOnly.result?.more == true)
    }

    /// A `subscribe` answer carries no messages and names no pane, the way the
    /// `recv` answer carries no events. The two verbs share one result type and
    /// nothing else.
    @Test func aBatchAnswerFillsNothingBelongingToAnotherVerb() {
        let response = ControlResponse.answer(
            for: EventBatch(
                events: [ControlEvent(seq: 1, kind: .paneOpened, pane: "p")],
                more: false,
                gap: false,
                seq: 1
            )
        )

        #expect(response.result?.messages == nil)
        #expect(response.result?.dropped == nil)
        #expect(response.result?.pane == nil)
        #expect(response.result?.panes == nil)
        #expect(response.result?.rendezvous == nil)
        #expect(response.result?.layout == nil)
    }
}
