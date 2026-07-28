import Foundation
import Testing

@testable import PaneControl

/// The write side's two bounds, and the frame a connection gets when it passes
/// one.
///
/// The defect this suite exists for: neither the outbound queue nor the hop to
/// the main actor had a bound at all, and both are reachable by a peer that has
/// not authenticated, because the token is checked on a frame that has already
/// been read. A peer that connected and then stopped reading, or one that wrote
/// faster than the app answered, could drive the app out of memory.
@Suite struct ConnectionBackpressureTests {
    static func line(_ bytes: Int) -> Data {
        Data(repeating: UInt8(ascii: "x"), count: bytes)
    }

    static func refusal(in pressure: ConnectionBackpressure) -> ControlError? {
        ControlWire.decodeResponse(Data(pressure.pending))?.error
    }

    // MARK: The outbound queue

    @Test func bytes_queue_up_and_leave_as_they_are_written() {
        var pressure = ConnectionBackpressure()

        #expect(pressure.isEmpty)
        #expect(pressure.queue(Data("ab".utf8)) == .accepted)
        #expect(pressure.queue(Data("cd".utf8)) == .accepted)
        #expect(pressure.pending == Array("abcd".utf8))

        pressure.wrote(3)
        #expect(pressure.pending == Array("d".utf8))
        pressure.wrote(1)
        #expect(pressure.isEmpty)
    }

    @Test func a_short_write_of_more_bytes_than_are_queued_empties_rather_than_traps() {
        var pressure = ConnectionBackpressure()
        _ = pressure.queue(Data("ab".utf8))

        pressure.wrote(99)
        #expect(pressure.isEmpty)

        // The negative is the same defensive case from the other side: `write(2)`
        // answers -1 on failure and the caller passes back what it was told.
        pressure.wrote(-1)
        #expect(pressure.isEmpty)
    }

    @Test func a_connection_owed_more_than_the_cap_is_refused_rather_than_held() {
        var pressure = ConnectionBackpressure()

        // Filled to the cap exactly, which is allowed: the bound is on what is
        // held, not on what has been asked for.
        #expect(pressure.queue(Self.line(ControlWire.maxOutboundBytes)) == .accepted)
        #expect(pressure.pending.count == ControlWire.maxOutboundBytes)

        #expect(pressure.queue(Self.line(1)) == .refused)
        #expect(pressure.isRefusing)
    }

    @Test func the_refusal_replaces_the_backlog_instead_of_queueing_behind_it() {
        var pressure = ConnectionBackpressure()
        _ = pressure.queue(Self.line(ControlWire.maxOutboundBytes))

        #expect(pressure.queue(Self.line(1)) == .refused)

        // The whole point of the bound: a peer that is not reading holds no bytes
        // in the app, so the queue after the refusal is the refusal alone.
        #expect(pressure.pending.count < 4096)
        #expect(Self.refusal(in: pressure)?.code == .refused)
    }

    @Test func the_outbound_cap_is_four_frames_so_answers_alone_never_reach_it() {
        // The two budgets are chosen together: a connection may have four
        // requests with the app, each answer may be a whole frame, and a client
        // that reads none of them until the last is answered rather than refused.
        #expect(ControlWire.maxOutboundBytes
            == ControlWire.maxInFlightRequests * ControlWire.maxFrameBytes)

        var pressure = ConnectionBackpressure()
        for _ in 0 ..< ControlWire.maxInFlightRequests {
            #expect(pressure.dispatch() == .accepted)
        }
        for _ in 0 ..< ControlWire.maxInFlightRequests {
            #expect(pressure.queue(Self.line(ControlWire.maxFrameBytes)) == .accepted)
        }
        #expect(pressure.isRefusing == false)
    }

    // MARK: The hop to the main actor

    @Test func a_fifth_unanswered_request_is_refused() {
        var pressure = ConnectionBackpressure()

        for _ in 0 ..< ControlWire.maxInFlightRequests {
            #expect(pressure.dispatch() == .accepted)
        }
        #expect(pressure.inFlight == ControlWire.maxInFlightRequests)

        #expect(pressure.dispatch() == .refused)
        #expect(Self.refusal(in: pressure)?.code == .refused)
    }

    @Test func answering_a_request_makes_room_for_the_next_one() {
        var pressure = ConnectionBackpressure()

        for _ in 0 ..< ControlWire.maxInFlightRequests {
            _ = pressure.dispatch()
        }
        #expect(pressure.queue(Data("answer\n".utf8)) == .accepted)
        #expect(pressure.inFlight == ControlWire.maxInFlightRequests - 1)

        #expect(pressure.dispatch() == .accepted)
    }

    /// The server writes frames nobody asked for: the idle sweep and the pool
    /// eviction both answer a connection that has nothing in flight.
    @Test func an_unsolicited_frame_does_not_drive_the_count_below_zero() {
        var pressure = ConnectionBackpressure()

        #expect(pressure.queue(Data("swept\n".utf8)) == .accepted)
        #expect(pressure.inFlight == 0)

        // The next connection to be counted here starts from zero and gets its
        // whole budget, rather than inheriting a head start from a negative one.
        for _ in 0 ..< ControlWire.maxInFlightRequests {
            #expect(pressure.dispatch() == .accepted)
        }
        #expect(pressure.dispatch() == .refused)
    }

    // MARK: What a refused connection does next

    @Test func nothing_is_taken_once_the_connection_is_refusing() {
        var pressure = ConnectionBackpressure()
        for _ in 0 ..< ControlWire.maxInFlightRequests { _ = pressure.dispatch() }
        _ = pressure.dispatch()

        let refusal = pressure.pending
        #expect(pressure.queue(Data("late answer\n".utf8)) == .dropped)
        #expect(pressure.dispatch() == .dropped)

        // Answers still on their way from the main actor arrive after the
        // decision to close and must not extend the queue past it.
        #expect(pressure.pending == refusal)
    }

    @Test func the_refusal_is_one_whole_line_that_fits_a_frame() {
        var pressure = ConnectionBackpressure()
        _ = pressure.queue(Self.line(ControlWire.maxOutboundBytes))
        _ = pressure.queue(Self.line(1))

        #expect(pressure.pending.last == UInt8(ascii: "\n"))
        #expect(ControlWire.fitsFrame(Data(pressure.pending)))
        #expect(ControlWire.decodeResponse(Data(pressure.pending))?.ok == false)
    }

    /// Measured against a real socket before it was fixed: the peer had taken
    /// 8192 bytes of a 250 KiB answer, the backlog was dropped, and the refusal
    /// landed on the end of that half line. The peer's first line was then
    /// neither the answer nor the refusal.
    @Test func a_refusal_after_a_half_written_frame_starts_on_a_line_of_its_own() {
        var pressure = ConnectionBackpressure()
        _ = pressure.queue(Self.line(ControlWire.maxOutboundBytes))
        pressure.wrote(8192)
        #expect(pressure.isMidFrame)

        // Past the cap again, and it takes a whole frame to get there: the eight
        // kilobytes the peer took back are eight kilobytes of room.
        #expect(pressure.queue(Self.line(ControlWire.maxOutboundBytes)) == .refused)

        #expect(pressure.pending.first == UInt8(ascii: "\n"))
        #expect(ControlWire.decodeResponse(Data(pressure.pending.dropFirst()))?.error?.code
            == .refused)
    }

    @Test func a_refusal_at_a_frame_boundary_carries_no_empty_line_before_it() {
        var pressure = ConnectionBackpressure()
        _ = pressure.queue(Data("{}\n".utf8))
        pressure.wrote(3)
        #expect(pressure.isMidFrame == false)

        for _ in 0 ... ControlWire.maxInFlightRequests { _ = pressure.dispatch() }

        // An empty line is not a response, and a client that has been sent one
        // has to decide what baia meant by it.
        #expect(pressure.pending.first == UInt8(ascii: "{"))
    }

    @Test func the_two_bounds_are_refused_with_different_messages() {
        var stopped = ConnectionBackpressure()
        _ = stopped.queue(Self.line(ControlWire.maxOutboundBytes))
        _ = stopped.queue(Self.line(1))

        var flooding = ConnectionBackpressure()
        for _ in 0 ... ControlWire.maxInFlightRequests { _ = flooding.dispatch() }

        // Both are `refused`, and a person reading one has to be able to tell
        // which budget they passed without reading this file.
        #expect(Self.refusal(in: stopped)?.code == .refused)
        #expect(Self.refusal(in: flooding)?.code == .refused)
        #expect(Self.refusal(in: stopped)?.message != Self.refusal(in: flooding)?.message)
    }

    @Test func a_hand_built_refusal_line_is_a_frame_the_cli_can_read() {
        // `ControlWire.refusal` promises a line where `encodeResponse` promises
        // an optional, and the byte layer leans on that promise at the one moment
        // it has nothing left to say.
        let line = ControlWire.refusal("no")
        #expect(ControlWire.decodeResponse(line)?.error?.code == .refused)
        #expect(line.last == UInt8(ascii: "\n"))
    }
}
