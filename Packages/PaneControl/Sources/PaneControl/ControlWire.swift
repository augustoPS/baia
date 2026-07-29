import Foundation

/// What a line off the socket turned into.
///
/// Two cases and no `throws`. The decode is where `badVersion`, `badFrame`, and
/// `unknownVerb` are produced, and producing them as a value rather than as an
/// error means the server has no error path that could hand a handler a
/// half-built request: there is either a whole one or a response to write back.
public enum ControlDecodeResult: Sendable, Equatable {
    case request(ControlRequest)
    case failure(ControlError)
}

/// The protocol: its version, its budgets, and the two directions of one line.
///
/// Newline-delimited JSON, one request per line, chosen over a length-prefixed
/// binary frame for one reason that outweighs efficiency at this volume: the
/// channel stays debuggable with `nc`, and a wire that can be exercised by hand
/// gets verified by hand.
public enum ControlWire {
    /// The only version this build speaks, as both sender and receiver.
    ///
    /// There is no negotiation. The CLI ships inside the app bundle and is built
    /// with the server, so a mismatch means a helper copied out of another
    /// build, and ``ControlError/badVersion(received:)`` says exactly that.
    public static let version = 1

    // MARK: Budgets
    //
    // Each of these stops something specific, and the note on each says what.
    // They live in the package rather than in the server so the CLI enforces the
    // same numbers on the way out that the server enforces on the way in, and a
    // client cannot discover a cap by having a connection closed on it.

    /// Per line, in either direction.
    ///
    /// Stops an unbounded allocation in the app process from a pane that never
    /// sends a newline, which is a workspace-wide denial of service out of one
    /// compromised pane. On the response side it stops a `recv` draining a full
    /// mailbox from owing a 16 MiB line.
    public static let maxFrameBytes = 256 * 1024

    /// Per message body.
    ///
    /// Set well below the frame cap because JSON string escaping can inflate
    /// control bytes up to sixfold, and a documented maximum that cannot
    /// actually be sent is worse than a lower one that can.
    ///
    /// The gap covers text, and it does not cover the sixfold worst case: 48 KiB
    /// of C0 control bytes frames to 288 KiB, which is over the cap. So `send`
    /// has to measure the framed size rather than the payload size, and refuse
    /// what it cannot frame. A payload accepted here that no response can carry
    /// would sit in a mailbox undrainable forever, since a message leaves the
    /// mailbox only once it has been framed into a response that fits. The
    /// arithmetic is pinned by a test rather than left in this comment.
    public static let maxMessagePayloadBytes = 48 * 1024

    /// Messages per mailbox. The oldest is dropped first and the drop count is
    /// reported by the next `recv`.
    public static let maxMailboxMessages = 256

    /// Messages per `recv`, with `more` set when the mailbox is not empty.
    public static let maxDrainBatch = 32

    /// Seconds a connection may sit without completing a request.
    public static let idleTimeoutSeconds = 30

    /// Seconds a `recv --wait` may park. An uncapped long poll is a slot held
    /// forever, so the client re-polls instead.
    public static let maxWaitSeconds = 60

    /// Connections in the pool.
    public static let maxConnections = 16

    /// Connections one pane may hold. The load-bearing half of the pair: without
    /// it, one pane fills the pool and every other pane's `baia` stops working.
    public static let maxConnectionsPerPane = 4

    /// Response bytes queued for one connection that has not read them.
    ///
    /// **The write side had no cap at all, and the write side is reachable
    /// before authentication.** The token is checked on a frame that has already
    /// been read, so anything that can open the socket can make the app allocate
    /// here, with the peer uid check and mode 0600 the only things in front of
    /// it. The socket is non-blocking and the flush never waits, on purpose, so
    /// a peer that connects and then stops reading leaves every byte it is owed
    /// in the app's memory rather than stalling the queue every other pane's
    /// `baia` shares. Without a bound that is the same workspace-wide denial of
    /// service ``maxFrameBytes`` stops in the other direction.
    ///
    /// Four frames, which is ``maxInFlightRequests`` times ``maxFrameBytes``, so
    /// a connection that pipelines to its in-flight cap and reads nothing until
    /// the last answer is never refused for answers it asked for.
    public static let maxOutboundBytes = 4 * maxFrameBytes

    /// Requests one connection may have with the app at once.
    ///
    /// The other half of the same hole. Every line the read loop cuts becomes a
    /// `Data` and a block on the main queue, and nothing waited for the app to
    /// answer before cutting the next one, so a peer writing faster than the
    /// main thread answers grew both without bound while holding the main thread
    /// down. Counting what is out and refusing past four bounds the main queue's
    /// backlog and, with ``maxOutboundBytes``, the memory one connection can
    /// reach.
    ///
    /// Four is above what the CLI and a hand-driven `nc` produce, since both
    /// read an answer before writing the next line, and far below a flood. The
    /// cost is that a script pipelining five frames without reading any answer
    /// is refused on the fifth, which is the trade the budget table records.
    public static let maxInFlightRequests = 4

    /// Bytes in a published channel name.
    ///
    /// Not in the spec's budget table and here for the same reason every row of
    /// it is: a name is echoed into the record `whoami` and `list` return, and a
    /// peer's `list` carries this pane's record, so an unbounded name is one pane
    /// making another pane's response unframeable. Cross-pane effect is the only
    /// privilege the channel grants, and this is a way to have one.
    public static let maxChannelNameBytes = 64

    /// Channels one pane may hold open at once.
    ///
    /// Same reasoning one level up: `publish` is idempotent per name, so a pane
    /// that keeps inventing names keeps adding table entries in the app process
    /// forever. Rotating or reusing a name is what a publisher actually wants.
    public static let maxPublishedChannelsPerPane = 16

    /// Bytes in any string an event carries.
    ///
    /// One cap for the attention message and the activity string rather than one
    /// each. OSC 9 text is untrusted pane output, and unbounded it is one pane
    /// making another pane's response unframeable, which is
    /// ``maxChannelNameBytes``'s argument one level along. The activity string is
    /// built from kernel-supplied names and is bounded already, so the rule costs
    /// it nothing and removes the question.
    public static let maxEventStringBytes = 512

    /// Events the ring holds, workspace-wide.
    ///
    /// One buffer for every subscriber rather than a queue each, so a slow
    /// subscriber costs itself a gap rather than costing the app memory.
    public static let maxRingEvents = 512

    /// Events one `subscribe` may carry.
    public static let maxEventBatch = 32

    /// The channel `baia publish` and `baia connect` mean when no `--as` is
    /// given.
    ///
    /// Here rather than in the CLI so that the client and the server cannot
    /// disagree about which channel a bare `publish` created.
    public static let defaultChannelName = "default"

    /// Whether a framed line fits the cap.
    ///
    /// Exists so the `recv` drain can frame a candidate response and ask, which
    /// is what makes "a message leaves the mailbox only once it has been framed
    /// into a response that fits" checkable rather than aspirational.
    public static func fitsFrame(_ line: Data) -> Bool {
        line.count <= maxFrameBytes
    }

    /// The size of the line a `recv` carrying exactly these messages would write.
    ///
    /// The whole response and not the messages alone, because the cap applies to
    /// the line: the envelope, the drop count, and the escaping are all part of
    /// what has to fit. `more` is spelled `false`, which is one byte longer than
    /// `true`, so a batch measured here is never larger when it is finally
    /// written.
    ///
    /// `Int.max` when the value cannot be encoded at all, which no response
    /// built from these types can be, so that an unencodable message is refused
    /// rather than accepted by a failure that reads as zero bytes.
    public static func drainFrameSize(messages: [ControlMessage], dropped: Int) -> Int {
        let response = ControlResponse.success(ControlResult(
            messages: messages,
            more: false,
            dropped: dropped
        ))
        guard let line = encodeResponse(response) else { return .max }
        return line.count
    }

    /// The framed size of a `subscribe` answer carrying these events.
    ///
    /// Measured rather than estimated, for ``drainFrameSize(messages:dropped:)``'s
    /// reason: an estimate wrong by one byte in the direction that matters either
    /// drops an event or writes a line the reader refuses.
    ///
    /// Both flags are spelled `false`, which is one byte longer than `true`, and
    /// `seq` is maximal, so the response finally written is never larger than the
    /// one that was measured.
    public static func eventBatchFrameSize(events: [ControlEvent]) -> Int {
        let response = ControlResponse.success(ControlResult(
            more: false,
            events: events,
            gap: false,
            seq: UInt64.max
        ))
        guard let line = encodeResponse(response) else { return .max }
        return line.count
    }

    /// Whether any `recv` could ever hand this message back.
    ///
    /// The check `send` enforces, and it is on the framed size rather than the
    /// payload size. The first draft of the spec's budget table claimed 48 KiB
    /// was chosen so that a maximal payload survived the worst case of JSON
    /// escaping. It does not: escaping spends six bytes on a control byte, and
    /// 48 KiB of U+0001 was measured at 295,037 bytes framed, well over the
    /// 256 KiB cap.
    ///
    /// The consequence is not cosmetic. A message leaves a mailbox only once it
    /// has been framed into a response that fits, so a payload accepted here that
    /// no response can carry would sit in a mailbox undrainable forever, blocking
    /// every message behind it.
    ///
    /// Measured against the worst drain that could carry it: this message alone,
    /// with a maximal drop count. Anything this accepts therefore fits as the
    /// first message of any drain, which is what keeps a mailbox making progress.
    public static func canBeDrained(_ message: ControlMessage) -> Bool {
        drainFrameSize(messages: [message], dropped: maxMailboxMessages) <= maxFrameBytes
    }

    // MARK: Encoding

    /// One request as a line, newline included, or nil when it could not be
    /// encoded at all.
    ///
    /// Nil is unreachable for any value a CLI builds, since the only encodable
    /// failure here is a non-finite `Double` in ``ControlArgs/by``. It is
    /// returned rather than force-tried because nothing in this project throws
    /// and a crash in the client is a worse answer than an exit status.
    ///
    /// The encoder emits no raw newline: a non-pretty JSON encoder writes no
    /// whitespace of its own and escapes a newline inside a string as `\n`, so
    /// the framing cannot be broken by a message body. A test holds that.
    public static func encodeRequest(_ request: ControlRequest) -> Data? {
        line(from: request)
    }

    /// One response as a line, newline included. Same nil rule as
    /// ``encodeRequest(_:)``.
    public static func encodeResponse(_ response: ControlResponse) -> Data? {
        line(from: response)
    }

    /// One `refused` line, ready to write, and never nil.
    ///
    /// The callers are the two places that have already decided to close the
    /// connection: the byte layer refusing a peer that passed a budget, and the
    /// accept loop refusing one that arrived past the pool. Neither has anything
    /// to fall back to, and neither may trap, so the hand-spelled literal stands
    /// in for the encode that cannot fail here anyway: the only encodable
    /// failure in this package is a non-finite `Double` in ``ControlArgs/by``,
    /// and a failure response carries none.
    ///
    /// The fallback's message is fixed rather than interpolated, because a
    /// message spliced into hand-written JSON would need escaping and the point
    /// of this path is that nothing on it can go wrong.
    public static func refusal(_ message: String) -> Data {
        let spelledByHand = "{\"v\":\(version),\"ok\":false,\"error\":{\"code\":\"refused\","
            + "\"message\":\"baia refused this connection.\"}}\n"
        return encodeResponse(.failure(.refused, message)) ?? Data(spelledByHand.utf8)
    }

    private static func line(from value: some Encodable) -> Data? {
        guard var data = try? JSONEncoder().encode(value) else { return nil }
        data.append(newline)
        return data
    }

    // MARK: Decoding

    /// One line into a request, or into the failure to answer it with.
    ///
    /// `line` may carry its trailing newline or not; the reader that split it
    /// off the socket is not made to care.
    ///
    /// The over-cap case answers `badFrame` for completeness, and the server
    /// never reaches it: rule 5's one carve-out is that a line exceeding the cap
    /// before a newline arrives is closed on without a response, because there
    /// is no parseable request to answer. That decision belongs to the read
    /// loop, which sees the bytes as they arrive, and not here, which only ever
    /// sees a line that already ended.
    public static func decodeRequest(_ line: Data) -> ControlDecodeResult {
        let payload = stripTrailingNewline(line)

        guard fitsFrame(payload) else {
            return .failure(.badFrame(
                "request frame is \(payload.count) bytes and the cap is \(maxFrameBytes)"
            ))
        }

        // Two passes, and the order is the point. The version is read on its own
        // first so that a v2 frame is answered `badVersion` even when the rest of
        // it is shaped in a way this build cannot decode, which is exactly the
        // frame a future version would send. Reading it in one pass would answer
        // `badFrame` for the one case the version field exists to explain.
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: payload) else {
            return .failure(.badFrame(
                "frame is not a JSON object carrying a numeric v"
            ))
        }
        guard probe.v == version else {
            return .failure(.badVersion(received: probe.v))
        }

        guard let envelope = try? decoder.decode(RequestEnvelope.self, from: payload) else {
            return .failure(.badFrame(
                "frame is missing a field a request needs: v, token, and verb are required"
            ))
        }

        // The verb arrives as a string and is looked up here rather than decoded
        // as a `ControlVerb`, because a synthesized decode of an unknown case
        // throws, and an unknown verb is an ordinary answer with its own error
        // code rather than a broken frame.
        guard let verb = ControlVerb(rawValue: envelope.verb) else {
            return .failure(.unknownVerb(envelope.verb))
        }

        return .request(ControlRequest(
            v: envelope.v,
            token: envelope.token,
            verb: verb,
            args: envelope.args ?? ControlArgs()
        ))
    }

    /// One line into a response, or nil when it is not one this build
    /// understands.
    ///
    /// Nil rather than a coded failure because the only reader is the CLI, which
    /// has exactly one thing to say about a response it cannot parse: the app it
    /// is talking to is not the build it shipped with.
    ///
    /// The version is checked on its own pass, the same way and for the same
    /// reason as in ``decodeRequest(_:)``. A response from another build decodes
    /// perfectly well into this shape, since `v` is just an `Int` the synthesized
    /// decoder accepts, so without this guard a v2 answer would be read as
    /// though it were a v1 answer, with whichever fields happened to survive.
    /// The request direction answers `badVersion` for the mirror image of that
    /// frame, and a wire where only one direction notices a version skew is a
    /// wire whose version field is decoration.
    public static func decodeResponse(_ line: Data) -> ControlResponse? {
        let payload = stripTrailingNewline(line)
        guard fitsFrame(payload) else { return nil }

        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: payload),
              probe.v == version
        else { return nil }

        return try? decoder.decode(ControlResponse.self, from: payload)
    }

    private static let newline = UInt8(0x0A)
    private static let carriageReturn = UInt8(0x0D)

    /// Drops one trailing `\n` and a `\r` before it.
    ///
    /// The `\r` is there for a hand-typed frame arriving from something that
    /// ends lines the DOS way, which is the diagnostic's `nc` on the wrong day,
    /// and costs one comparison to accept.
    private static func stripTrailingNewline(_ line: Data) -> Data {
        var end = line.endIndex
        if end > line.startIndex, line[line.index(before: end)] == newline {
            end = line.index(before: end)
        }
        if end > line.startIndex, line[line.index(before: end)] == carriageReturn {
            end = line.index(before: end)
        }
        return line[line.startIndex ..< end]
    }

    /// The version field on its own, so it can be read before anything else can
    /// fail.
    private struct VersionProbe: Decodable {
        var v: Int
    }

    /// The request as it arrives, with the verb still a string.
    ///
    /// `args` is optional here and non-optional on ``ControlRequest``: a frame
    /// typed by hand for a verb that needs no arguments should not have to carry
    /// an empty object, and every request the CLI builds carries one anyway.
    private struct RequestEnvelope: Decodable {
        var v: Int
        var token: String
        var verb: String
        var args: ControlArgs?
    }
}
