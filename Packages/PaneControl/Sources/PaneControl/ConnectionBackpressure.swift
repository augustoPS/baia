import Foundation

/// One connection's write side: the bytes it is owed and has not read, and the
/// requests it has with the app and has not been answered.
///
/// **Here rather than in the transport for ``ParkedRecvs``' reason.** Both bounds
/// are decidable without a descriptor, a socket, or a run loop, so `make test`
/// decides them and the transport is left holding nothing but the file
/// descriptor and the question.
///
/// **Why the write side needed a bound at all.** The read side is capped by
/// ``ControlWire/maxFrameBytes`` and the pool by ``ControlWire/maxConnections``,
/// and neither reaches this direction. A response is appended to a per-connection
/// buffer and the socket is non-blocking, so a peer that connects and stops
/// reading holds that buffer in the app's memory; every line the read loop cuts
/// becomes a block on the main queue, so a peer that writes faster than the app
/// answers holds a growing backlog there too. The peer does not have to
/// authenticate to reach either one: the token is checked on a frame that has
/// already been read, so the reachable surface is anything that can open the
/// socket, with the peer uid check and mode 0600 the only things in front of it.
///
/// The answer to passing either bound is spec rule 5's, closed and total: one
/// `refused` frame replaces whatever was queued, and the connection closes once
/// that frame has been written or has failed to be. Dropping the backlog is not
/// a shortcut. A peer that passed either bound is a peer that is not reading what
/// it is already owed, so those bytes are bytes nobody will ever read, and
/// holding them while writing the refusal would be the same allocation wearing an
/// apology.
public struct ConnectionBackpressure: Sendable, Equatable {
    /// What the caller does next.
    ///
    /// A returned outcome rather than a silent truncation, for the reason
    /// ``ParkedRecvs/ParkOutcome`` is one: the caller owes the connection an
    /// action either way, and the only way to make that impossible to forget is
    /// to make it impossible to ignore the answer.
    public enum Outcome: Sendable, Equatable {
        /// Carry on.
        case accepted

        /// A budget was passed. ``pending`` now holds one `refused` line and
        /// nothing else: stop reading this connection, write what is there, and
        /// close.
        case refused

        /// This connection is already closing on an earlier refusal, so nothing
        /// was taken and nothing more will be.
        case dropped
    }

    /// Bytes written to the socket, oldest first.
    public private(set) var pending: [UInt8] = []

    /// Requests handed to the app and not yet answered.
    public private(set) var inFlight = 0

    /// Whether the connection is closing on a refusal this type produced.
    public private(set) var isRefusing = false

    /// Whether the peer has been sent part of a line and not the newline that
    /// ends it.
    ///
    /// Tracked so the refusal below cannot glue itself onto a half-written frame.
    /// The server already refuses to truncate a response for this reason: a
    /// client reading a half line answers for baia, and what it says is that the
    /// app is broken. Dropping a backlog mid-frame is the same truncation from
    /// the other end, and it was measured doing exactly that.
    public private(set) var isMidFrame = false

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }

    /// Counts one line on its way to the app, or refuses a connection that is
    /// asking faster than it is being answered.
    ///
    /// Called before the line is handed over rather than after, because the point
    /// is to not hand it over: the allocation this bounds is the one the hop
    /// itself makes.
    public mutating func dispatch() -> Outcome {
        guard isRefusing == false else { return .dropped }
        guard inFlight < ControlWire.maxInFlightRequests else {
            return refuse(with: .tooManyRequestsInFlight)
        }
        inFlight += 1
        return .accepted
    }

    /// Queues one response line, or refuses a connection that has stopped
    /// reading.
    public mutating func queue(_ line: Data) -> Outcome {
        guard isRefusing == false else { return .dropped }

        // Saturating, and not every line answers a request: the server writes an
        // unsolicited `refused` to a connection it is sweeping for idleness or
        // evicting from a full pool. A counter that went negative there would
        // hand the next connection to reuse the slot a head start on the cap,
        // and one that trapped would take the app down over a housekeeping
        // frame. Undercounting costs at most one slot of slack, which a bound
        // can afford; unbounded growth is what it cannot.
        inFlight = max(0, inFlight - 1)

        guard pending.count + line.count <= ControlWire.maxOutboundBytes else {
            return refuse(with: .outboundQueueFull)
        }
        pending.append(contentsOf: line)
        return .accepted
    }

    /// Drops the bytes that made it onto the socket.
    ///
    /// Clamped rather than trusting the count, because the caller is passing back
    /// what `write(2)` said and a short write is the ordinary case here.
    public mutating func wrote(_ count: Int) {
        let taken = min(max(count, 0), pending.count)
        if taken > 0 { isMidFrame = pending[taken - 1] != Self.newline }
        pending.removeFirst(taken)
    }

    private mutating func refuse(with error: ControlError) -> Outcome {
        // The newline first when the peer is holding half a line, so the refusal
        // arrives as a line of its own rather than as the tail of a frame the
        // backlog was cut out from under.
        pending = isMidFrame ? [Self.newline] : []
        pending.append(contentsOf: ControlWire.refusal(error.message))
        // Nothing in flight will be counted back: the connection closes once this
        // line is written, and the answers still on their way find no connection
        // to be written to.
        inFlight = 0
        isRefusing = true
        return .refused
    }

    private static let newline = UInt8(0x0A)
}
