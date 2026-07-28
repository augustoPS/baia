import Darwin
import Foundation
import PaneControl

/// What the socket layer tells the server, always on the channel queue and never
/// on the main thread.
///
/// Closures rather than a delegate protocol, because the one implementer is
/// `ControlServer` and a protocol would have to be `Sendable` and non-isolated
/// while every method it declared hopped straight to the main actor. Passed in at
/// bind time rather than settable afterwards, so there is no window where the
/// listener is accepting and nobody is listening back.
nonisolated struct ControlTransportHandlers: Sendable {
    /// A connection cleared the peer credential check and now holds a pool slot.
    var accepted: @Sendable (Int) -> Void

    /// One complete line, with its newline already taken off.
    var line: @Sendable (Int, Data) -> Void

    /// The frame cap was passed before a newline arrived, so there is no
    /// parseable request to answer and the connection is already closed. Rule
    /// 5's single carve-out: everything else fails with a response.
    var oversized: @Sendable (Int) -> Void

    /// The connection is gone, by EOF, by error, or because the server asked.
    var closed: @Sendable (Int) -> Void
}

/// The listening socket, the accept loop, and one framed byte stream per
/// connection.
///
/// **BSD sockets on a GCD source, not `Network.framework`.** `NWListener`'s
/// unix-domain support is undocumented enough that discovering its shape belongs
/// to a working afternoon rather than to whatever hour a pane's `baia` stops
/// answering, and everything below is `socket`, `bind`, `listen`, `accept`,
/// `read`, `write` with a `DispatchSource` per descriptor.
///
/// **Everything here is confined to one serial queue** and nothing here touches
/// the main actor, `PaneGraph`, or any part of the app. That is what makes the
/// `@unchecked Sendable` honest: the only members are touched inside `queue`,
/// the public methods hop onto it themselves, and the values that cross the
/// boundary are `Int`, `Data`, and the handler closures.
///
/// The queue is `.utility` rather than `.userInitiated`: a pane waiting on
/// `baia split` is waiting on a person's keystroke either way, and the terminal's
/// own rendering has the better claim on a core.
nonisolated final class ControlTransport: @unchecked Sendable {
    /// What binding the socket did, which is a launch-time decision the app has
    /// to see rather than a log line.
    enum BindOutcome {
        case bound

        /// Something answered on the socket, so another baia owns it. This
        /// instance runs without a channel and injects no `BAIA_SOCK`, because
        /// handing its panes the *first* instance's live socket would answer
        /// `badToken` with a completely misleading story.
        case ownedByAnotherInstance

        case failed(String)
    }

    private let path: String
    private let queue = DispatchQueue(label: "gutons.baia.control", qos: .utility)

    private var handlers = ControlTransportHandlers(
        accepted: { _ in },
        line: { _, _ in },
        oversized: { _ in },
        closed: { _ in }
    )

    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int: Connection] = [:]
    private var nextID = 1
    private var isBound = false

    init(path: String) {
        self.path = path
    }

    // MARK: Binding

    /// Takes the socket, or says who has it.
    ///
    /// Synchronous, on the caller's thread, because the answer decides what every
    /// pane this instance opens is told about `BAIA_SOCK`, and a launch that
    /// learned it a moment later would have already spawned a pane.
    ///
    /// **The stale socket is resolved by connecting, not by stat.** A socket file
    /// left by a crash looks exactly like a live one on disk, and unlinking on
    /// sight would let a second baia steal the first one's channel out from under
    /// its panes. So: connect first, and unlink only on refusal, which is what a
    /// socket with no listener answers.
    func bind(handlers: ControlTransportHandlers) -> BindOutcome {
        queue.sync {
            self.handlers = handlers
            return bindOnQueue()
        }
    }

    private func bindOnQueue() -> BindOutcome {
        guard Self.createDirectory(for: path) else {
            return .failed("could not create the directory for \(path)")
        }

        var probe = sockaddr_un()
        switch Self.fill(&probe, with: path) {
        case let .failure(reason):
            return .failed(reason)
        case .success:
            break
        }

        if access(path, F_OK) == 0 {
            if Self.somethingIsListening(at: probe) {
                return .ownedByAnotherInstance
            }
            // Refused, so the owner is gone. The file is the corpse, not the
            // channel.
            unlink(path)
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return .failed("could not open a socket: \(Self.reason(errno))")
        }

        // Close-on-exec is load-bearing rather than tidy. Ghostty spawns a login
        // shell per pane, and a listening descriptor without this flag is
        // inherited by every one of them: a pane could then accept its own
        // connections on baia's socket, which is the whole channel handed to the
        // adversary the channel exists to bound.
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)

        let bound = withUnsafePointer(to: &probe) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let reason = Self.reason(errno)
            Darwin.close(descriptor)
            return .failed("could not bind \(path): \(reason)")
        }

        // 0600 after the bind rather than through umask, which is process-wide
        // and would be a global side effect for a local guarantee. The mode
        // excludes other users; it does not exclude other processes of this user,
        // which is why the token check exists and why this is defence in depth.
        _ = chmod(path, 0o600)

        guard Darwin.listen(descriptor, 32) == 0 else {
            let reason = Self.reason(errno)
            Darwin.close(descriptor)
            unlink(path)
            return .failed("could not listen on \(path): \(reason)")
        }

        listener = descriptor
        isBound = true

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        // The descriptor is closed by the cancel handler and nowhere else, so
        // there is one owner of its lifetime and no path where a cancelled source
        // fires on a descriptor some other code already recycled.
        source.setCancelHandler { Darwin.close(descriptor) }
        acceptSource = source
        source.resume()

        return .bound
    }

    /// Whether a live baia answers on this address.
    ///
    /// A connect and an immediate close. Anything other than success means no
    /// owner: `ECONNREFUSED` for a socket file whose process died, `ENOENT` for a
    /// path that lost its file between the `access` above and here.
    private static func somethingIsListening(at address: sockaddr_un) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var probe = address
        let connected = withUnsafePointer(to: &probe) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }

    // MARK: Accepting

    private func acceptPending() {
        while true {
            let descriptor = Darwin.accept(listener, nil, nil)
            guard descriptor >= 0 else {
                let code = errno
                if code == EINTR || code == ECONNABORTED { continue }
                return
            }

            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)

            // Without this a client that died between its request and our
            // response raises SIGPIPE inside the app, and the whole workspace
            // goes down because one pane's shell was killed mid-command.
            var on: Int32 = 1
            _ = setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &on,
                socklen_t(MemoryLayout<Int32>.size)
            )

            // **Before a single byte is read.** Defence in depth and never
            // authentication: mode 0600 in a user-owned directory already
            // excludes other users, and a same-uid peer is not thereby trusted,
            // because the token check still runs on every request. A peer whose
            // uid does not match gets no frame at all, because there is nothing
            // to tell a process that should not have reached this socket.
            guard Self.peerIsThisUser(descriptor) else {
                Darwin.close(descriptor)
                continue
            }

            let id = nextID
            nextID += 1
            let connection = Connection(id: id, descriptor: descriptor)
            connections[id] = connection

            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.readPending(connection) }
            source.setCancelHandler { Darwin.close(descriptor) }
            connection.reader = source
            source.resume()

            handlers.accepted(id)
        }
    }

    /// Whether the process on the other end runs as this user.
    ///
    /// `LOCAL_PEERCRED` rather than `getpeereid`, which is a wrapper over exactly
    /// this call: the credentials are read from the socket by the kernel at
    /// connect time, so there is nothing a peer can present or forge here.
    private static func peerIsThisUser(_ descriptor: Int32) -> Bool {
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        let read = getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &length)
        guard read == 0, credentials.cr_version == XUCRED_VERSION else { return false }
        return credentials.cr_uid == getuid()
    }

    // MARK: Reading

    private func readPending(_ connection: Connection) {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            let count = chunk.withUnsafeMutableBufferPointer { buffer in
                Darwin.read(connection.descriptor, buffer.baseAddress, buffer.count)
            }

            if count == 0 {
                tearDown(connection, notify: true)
                return
            }

            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK { return }
                tearDown(connection, notify: true)
                return
            }

            connection.inbound.append(contentsOf: chunk[0 ..< count])

            // Lines first, then the tail. A 300 KiB line that arrived whole, in
            // one read, exceeded the cap before its newline did, so it is the
            // same case as a client that never sends one and gets the same
            // answer: none.
            while let end = connection.inbound.firstIndex(of: Self.newline) {
                let line = Array(connection.inbound[..<end])
                connection.inbound.removeFirst(end + 1)
                guard line.count <= ControlWire.maxFrameBytes else {
                    handlers.oversized(connection.id)
                    tearDown(connection, notify: true)
                    return
                }
                handlers.line(connection.id, Data(line))
            }

            guard connection.inbound.count <= ControlWire.maxFrameBytes else {
                handlers.oversized(connection.id)
                tearDown(connection, notify: true)
                return
            }
        }
    }

    // MARK: Writing

    /// Queues one line and, optionally, the close that follows it.
    ///
    /// `thenClose` closes *after* the bytes have left, which is the ordering
    /// `baia close` depends on: the pane it kills takes the client with it, so a
    /// response written after the close would be a response nobody could ever
    /// have read.
    func send(_ line: Data, to id: Int, thenClose: Bool = false) {
        queue.async { [weak self] in
            guard let self, let connection = connections[id] else { return }
            connection.outbound.append(contentsOf: line)
            if thenClose { connection.closeAfterFlush = true }
            flush(connection)
        }
    }

    func close(_ id: Int) {
        queue.async { [weak self] in
            guard let self, let connection = connections[id] else { return }
            tearDown(connection, notify: true)
        }
    }

    /// Writes what it can and arms a write source for what it cannot.
    ///
    /// The descriptor is non-blocking and the loop never waits, because this
    /// queue serves every pane's channel: a client that stopped reading mid-
    /// response would otherwise stall `baia` in every other pane for as long as
    /// it felt like it, which is the workspace-wide denial of service the budget
    /// table exists to stop, arriving through the one direction the caps do not
    /// cover.
    private func flush(_ connection: Connection) {
        while connection.outbound.isEmpty == false {
            let written = connection.outbound.withUnsafeBufferPointer { buffer in
                Darwin.write(connection.descriptor, buffer.baseAddress, buffer.count)
            }

            if written > 0 {
                connection.outbound.removeFirst(written)
                continue
            }

            let code = errno
            if written < 0, code == EINTR { continue }
            if written < 0, code == EAGAIN || code == EWOULDBLOCK {
                arm(connection)
                return
            }
            tearDown(connection, notify: true)
            return
        }

        disarm(connection)
        if connection.closeAfterFlush {
            tearDown(connection, notify: true)
        }
    }

    private func arm(_ connection: Connection) {
        guard connection.writer == nil else { return }
        let source = DispatchSource.makeWriteSource(
            fileDescriptor: connection.descriptor,
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.flush(connection) }
        connection.writer = source
        source.resume()
    }

    /// Cancels rather than suspends. A suspended `DispatchSource` that is then
    /// released traps, and the write source exists only while there are bytes
    /// waiting, so cancelling on empty is both the cheap path and the safe one.
    private func disarm(_ connection: Connection) {
        connection.writer?.cancel()
        connection.writer = nil
    }

    // MARK: Teardown

    private func tearDown(_ connection: Connection, notify: Bool) {
        guard connection.isTornDown == false else { return }
        connection.isTornDown = true
        connections[connection.id] = nil

        disarm(connection)
        // The reader owns the descriptor's lifetime, so it is cancelled last and
        // its cancel handler is the only `close`.
        connection.reader?.cancel()
        connection.reader = nil

        if notify { handlers.closed(connection.id) }
    }

    /// Flushes what is queued, drops every connection, and takes the socket file
    /// with it.
    ///
    /// `sync`, and that is the point: every response queued before this call has
    /// already run through the same serial queue, so a parked `recv` resolved at
    /// terminate has had its write attempted before the descriptor closes. A
    /// waiter is resolved and never abandoned, and an empty drain is 60 bytes,
    /// which no socket buffer this side of a wedged kernel refuses.
    func shutdown() {
        queue.sync {
            for connection in connections.values {
                flush(connection)
                tearDown(connection, notify: false)
            }
            acceptSource?.cancel()
            acceptSource = nil
            listener = -1
            if isBound {
                unlink(path)
                isBound = false
            }
        }
    }

    // MARK: One connection's bytes

    /// Confined to the channel queue, like everything else here. A class rather
    /// than a struct because a `DispatchSource` handler captures it and has to
    /// see the same buffers the read loop is filling.
    private final class Connection {
        let id: Int
        let descriptor: Int32
        var reader: DispatchSourceRead?
        var writer: DispatchSourceWrite?
        var inbound: [UInt8] = []
        var outbound: [UInt8] = []
        var closeAfterFlush = false
        var isTornDown = false

        init(id: Int, descriptor: Int32) {
            self.id = id
            self.descriptor = descriptor
        }
    }

    // MARK: Addresses and directories

    private enum FillResult {
        case success
        case failure(String)
    }

    /// Copies the path into `sun_path`, which is 104 bytes and not a `String`.
    ///
    /// Checked rather than trusted, the way the CLI checks it. The documented
    /// path sits well under the cap, and a truncated one would bind a socket at a
    /// path nothing would ever connect to while reporting success.
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

    /// Creates the directory the socket sits in, 0700, the way `SessionStore`
    /// creates the one it shares with `session.json`.
    ///
    /// `mkdir(2)` rather than `FileManager.createDirectory`, which throws for the
    /// case that is not a failure: the directory already being there, which it
    /// is on every launch after the first.
    private static func createDirectory(for socketPath: String) -> Bool {
        let directory = (socketPath as NSString).deletingLastPathComponent
        guard directory.hasPrefix("/") else { return false }

        var built = ""
        for component in directory.split(separator: "/") {
            built += "/" + component
            if mkdir(built, 0o700) != 0, errno != EEXIST { return false }
        }
        return true
    }

    private static let newline = UInt8(0x0A)

    private static func reason(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
