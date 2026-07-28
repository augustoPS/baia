import Darwin
import Foundation
import PaneControl

/// What one exchange over the socket produced.
enum ExchangeOutcome {
    case answered(ControlResponse)

    /// The app closed the connection without writing a frame.
    ///
    /// Only `close` may treat this as success, and it does: the verb kills the
    /// shell that invoked it, and with it this process's parent. The server
    /// writes and flushes before scheduling the close, so a live client sees
    /// `ok`, and a client that lost the race sees the pane it asked to close go
    /// away underneath it. Both are the request having worked.
    case closedWithoutAnswer

    /// Nothing usable came back, and this is what happened.
    case broken(String)
}

/// One request down a unix domain socket, one line back.
///
/// A socket rather than XPC or a Mach service, and the deciding reason is in the
/// spec: the wire stays exercisable by hand with `nc`, and a wire that can be
/// driven by hand gets verified by hand. Ad-hoc signing also makes an audit
/// token's code-signature check near worthless, so native IPC would buy peer
/// identity the token model does not use.
struct ControlClient {
    let socketPath: String

    /// Sends `request` and waits for one line.
    ///
    /// `readTimeoutSeconds` bounds the wait so a wedged app cannot leave a shell
    /// hanging with no way to tell what happened. It is derived from the
    /// protocol's own caps by the caller rather than guessed here.
    func exchange(_ request: ControlRequest, readTimeoutSeconds: Int) -> ExchangeOutcome {
        guard let line = ControlWire.encodeRequest(request) else {
            return .broken("the request could not be encoded")
        }
        guard ControlWire.fitsFrame(line) else {
            return .broken(
                "the request frames to \(line.count) bytes and the cap is "
                    + "\(ControlWire.maxFrameBytes)"
            )
        }

        var address = sockaddr_un()
        switch Self.fill(&address, with: socketPath) {
        case let .failure(reason):
            return .broken(reason)
        case .success:
            break
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return .broken("could not open a socket: \(Self.reason(errno))")
        }
        defer { Darwin.close(descriptor) }

        // Without this, writing to a socket the app already closed raises
        // SIGPIPE and kills the CLI with no exit status a script can read, which
        // is the worst possible answer to "the app went away".
        var on: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        Self.setTimeout(descriptor, SO_RCVTIMEO, seconds: readTimeoutSeconds)
        Self.setTimeout(descriptor, SO_SNDTIMEO, seconds: ControlWire.idleTimeoutSeconds)

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            if code == ECONNREFUSED {
                return .broken(
                    "no baia is listening on \(socketPath). The socket is there and its owner "
                        + "is not, which is a baia that died rather than quit."
                )
            }
            if code == ENOENT {
                return .broken(
                    "there is no socket at \(socketPath). BAIA_SOCK names a path the app never "
                        + "bound, which is a helper copied out of the bundle it belongs to."
                )
            }
            return .broken("could not reach \(socketPath): \(Self.reason(code))")
        }

        if let failure = Self.writeAll(line, to: descriptor) {
            return .broken(failure)
        }

        return Self.readOneLine(from: descriptor)
    }

    // MARK: Address

    private enum FillResult {
        case success
        case failure(String)
    }

    /// Copies the path into `sun_path`, which is 104 bytes and not a String.
    ///
    /// The cap is checked rather than trusted. The documented path sits well
    /// under it, and `$BAIA_SOCK` arrives from the environment, so a truncated
    /// path would otherwise connect to whatever the prefix happened to name.
    private static func fill(_ address: inout sockaddr_un, with path: String) -> FillResult {
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            return .failure(
                "the socket path is \(bytes.count) bytes and a unix socket takes at most "
                    + "\(capacity - 1)"
            )
        }

        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (offset, byte) in bytes.enumerated() {
                    destination[offset] = CChar(bitPattern: byte)
                }
                destination[bytes.count] = 0
            }
        }
        return .success
    }

    private static func setTimeout(_ descriptor: Int32, _ option: Int32, seconds: Int) {
        var window = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            option,
            &window,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    // MARK: Bytes

    /// Writes the whole line or says why it could not.
    ///
    /// A loop rather than one `write`, because a short write on a stream socket
    /// is ordinary and a request truncated mid-JSON would be answered `badFrame`
    /// by a server that did nothing wrong.
    private static func writeAll(_ line: Data, to descriptor: Int32) -> String? {
        var sent = 0
        let bytes = [UInt8](line)
        while sent < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer in
                Darwin.write(descriptor, buffer.baseAddress! + sent, bytes.count - sent)
            }
            if written > 0 {
                sent += written
                continue
            }
            if written < 0, errno == EINTR {
                continue
            }
            return "the request could not be written: \(reason(errno))"
        }
        return nil
    }

    /// Reads until the first newline, the cap, or the end.
    private static func readOneLine(from descriptor: Int32) -> ExchangeOutcome {
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            let count = chunk.withUnsafeMutableBufferPointer { buffer in
                Darwin.read(descriptor, buffer.baseAddress!, buffer.count)
            }

            if count < 0 {
                let code = errno
                if code == EINTR {
                    continue
                }
                if code == EAGAIN || code == EWOULDBLOCK {
                    return .broken("baia did not answer in time")
                }
                return .broken("the answer could not be read: \(reason(code))")
            }

            if count == 0 {
                if received.isEmpty {
                    return .closedWithoutAnswer
                }
                return .broken("baia closed the connection part way through its answer")
            }

            received.append(contentsOf: chunk[0 ..< count])

            if let end = received.firstIndex(of: UInt8(0x0A)) {
                let line = received[received.startIndex ... end]
                guard let response = ControlWire.decodeResponse(Data(line)) else {
                    return .broken(
                        "baia answered something this build cannot read, which means this helper "
                            + "was copied out of a different build of the app"
                    )
                }
                return .answered(response)
            }

            // The same cap the server enforces on the way in. A response that
            // never ends is the mirror image of a request that never ends, and
            // an unbounded read here would let a wedged app grow this process
            // without limit inside somebody's pane.
            if received.count > ControlWire.maxFrameBytes {
                return .broken(
                    "baia's answer passed \(ControlWire.maxFrameBytes) bytes with no end of line"
                )
            }
        }
    }

    private static func reason(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
