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

    /// Whether a framed line fits the cap.
    ///
    /// Exists so the `recv` drain can frame a candidate response and ask, which
    /// is what makes "a message leaves the mailbox only once it has been framed
    /// into a response that fits" checkable rather than aspirational.
    public static func fitsFrame(_ line: Data) -> Bool {
        line.count <= maxFrameBytes
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
