import Darwin
import Foundation
import PaneControl
import WorkspaceLayout

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
        let directory = (path as NSString).deletingLastPathComponent
        guard SessionStore.createDirectory(atPath: directory) else {
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
            return .failed("could not open a socket: \(SystemError.reason(errno))")
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
            let reason = SystemError.reason(errno)
            Darwin.close(descriptor)
            return .failed("could not bind \(path): \(reason)")
        }

        // 0600 after the bind rather than through umask, which is process-wide
        // and would be a global side effect for a local guarantee. The mode
        // excludes other users; it does not exclude other processes of this user,
        // which is why the token check exists and why this is defence in depth.
        _ = chmod(path, 0o600)

        guard Darwin.listen(descriptor, 32) == 0 else {
            let reason = SystemError.reason(errno)
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

            // Refused here rather than only on the main actor, and refused
            // before a descriptor is held, a source is armed, or a hop is made.
            // The pool cap is the server's and so is its eviction policy, but a
            // cap enforced only a layer up is one an unauthenticated peer walks
            // straight past: accept is synchronous and the hop that consults the
            // pool is not, so a connect loop holds descriptors faster than the
            // main thread can refuse them, until the app runs out and Ghostty
            // cannot spawn a shell.
            guard connections.count < Self.acceptCeiling else {
                Self.writeAndClose(descriptor, Self.ceilingRefusal)
                continue
            }

            let id = nextID
            nextID += 1
            let connection = Connection(id: id, descriptor: descriptor)
            connections[id] = connection

            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.readPending(connection) }
            // Held before the source can be cancelled, released by the cancel
            // handler, and the close belongs to whichever hold is the last to go.
            // See ``DescriptorHandle``.
            let handle = connection.handle
            handle.hold()
            source.setCancelHandler { handle.release() }
            connection.reader = source
            source.resume()

            handlers.accepted(id)
        }
    }

    /// The pool cap, plus the one arrival the pool cap is decided about.
    ///
    /// ``ControlServer`` owns the pool, and its answer to a full one is a
    /// main-actor decision this queue cannot make: a full pool gives up a parked
    /// `recv` when it has one and refuses when it does not, and only the server
    /// knows which. So an arriving connection is held long enough for that hop to
    /// happen, and this is the sixteen already in hand plus that one. Everything
    /// past it is refused on this queue, where refusing costs no descriptor.
    private static let acceptCeiling = ControlWire.maxConnections + 1

    private static let ceilingRefusal = ControlWire.refusal(
        "baia is holding \(ControlWire.maxConnections) control connections and cannot take another "
            + "until one of them finishes. Try again."
    )

    /// Writes one line to a descriptor nothing is listening on yet, then closes
    /// it.
    ///
    /// For the refusal above, which happens before there is a connection to own
    /// the descriptor or a source to close it, so the close is unambiguous here
    /// and needs no ``DescriptorHandle``. Best effort by construction: the socket
    /// is non-blocking, this is the first thing ever written to it, and a peer
    /// whose receive buffer cannot take two hundred bytes is a peer that is not
    /// reading. Arming a write source for it would be arming a source on a
    /// descriptor whose whole purpose is to be gone.
    private static func writeAndClose(_ descriptor: Int32, _ line: Data) {
        line.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let written = Darwin.write(descriptor, base + sent, buffer.count - sent)
                if written > 0 {
                    sent += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                break
            }
        }
        Darwin.close(descriptor)
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

                // Counted before the hop and not after, because the allocation
                // being bounded is the hop's own: one `Data` and one block on the
                // main queue per line, made by a peer that need not have
                // authenticated to make them.
                switch connection.pressure.dispatch() {
                case .accepted:
                    handlers.line(connection.id, Data(line))
                case .refused, .dropped:
                    // `dropped` is unreachable, since refusing cancels this
                    // source on the way past, and it goes the same way anyway: a
                    // read source left armed on bytes nobody will consume is a
                    // handler that fires forever.
                    refuse(connection)
                    return
                }
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

            switch connection.pressure.queue(line) {
            case .accepted:
                if thenClose { connection.closeAfterFlush = true }
                flush(connection)
            case .refused:
                // The started frame is finished through its newline; later
                // queued frames are gone; the refusal follows. A peer that is
                // this far behind still gets one complete first line.
                refuse(connection)
            case .dropped:
                // Already refusing and already closing, so the answers still on
                // their way from the main actor stop here. `thenClose` does not:
                // a peer that trips a budget and then stops reading altogether
                // leaves its refusal unwritable and its descriptor held, and the
                // one thing that reclaims it is the server deciding it has waited
                // long enough. That decision arrives as this flag, from the idle
                // sweep, and dropping it would let such a peer hold a slot until
                // the app quit.
                if thenClose { tearDown(connection, notify: true) }
            }
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
    /// table exists to stop.
    ///
    /// Not waiting turns time into memory, which is why the write side carries
    /// budgets of its own. ``ConnectionBackpressure`` holds them, and the peer
    /// they bound need not have authenticated: the token is read out of a frame
    /// that has already arrived here.
    private func flush(_ connection: Connection) {
        while connection.pressure.isEmpty == false {
            let written = connection.pressure.pending.withUnsafeBufferPointer { buffer in
                Darwin.write(connection.descriptor, buffer.baseAddress, buffer.count)
            }

            if written > 0 {
                connection.pressure.wrote(written)
                continue
            }

            let code = errno
            if written < 0, code == EINTR { continue }
            if written < 0, code == EAGAIN || code == EWOULDBLOCK {
                arm(connection)
                if connection.closeAfterFlush { armCloseDeadline(connection) }
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

    /// Gives a connection that has been told to close the idle budget to take its
    /// last frame, and then takes the descriptor back whether it did or not.
    ///
    /// **Without this the accept ceiling would be a way to lock the channel
    /// shut.** A peer that opens connections and reads nothing leaves every
    /// closing frame unwritable, so the descriptor waits on a peer that has no
    /// intention of reading, and the ceiling that bounds descriptors would then
    /// bound them at seventeen held forever. Two of the closing frames are not
    /// even the server's to time out: the pool refuses an arrival it never
    /// admitted, so no idle sweep will ever look at it, and a connection this
    /// queue refused for backpressure is closing on a decision the server has not
    /// been told about yet.
    ///
    /// ``ControlWire/idleTimeoutSeconds`` rather than a number of its own,
    /// because this is the same judgement the sweep makes: a connection that has
    /// held a slot for thirty seconds without making progress has had it.
    private func armCloseDeadline(_ connection: Connection) {
        guard connection.hasCloseDeadline == false else { return }
        connection.hasCloseDeadline = true
        // The id and not the connection, the way ``send(_:to:thenClose:)`` takes
        // one: a `Connection` is confined to this queue and is not `Sendable`, and
        // an id is an `Int` that names the same connection for the life of the
        // run because ids are never reused. A connection that has already gone is
        // simply not found.
        let id = connection.id
        queue.asyncAfter(deadline: .now() + .seconds(ControlWire.idleTimeoutSeconds)) {
            [weak self] in
            guard let self, let connection = connections[id] else { return }
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
        let handle = connection.handle
        handle.hold()
        source.setCancelHandler { handle.release() }
        connection.writer = source
        source.resume()
    }

    /// Stops reading a connection that passed a budget, and writes it the one
    /// frame it has left.
    ///
    /// ``ConnectionBackpressure`` has already put the refusal where the backlog
    /// was; this stops the other direction. The read source is cancelled rather
    /// than left armed, because it is level triggered on bytes this connection
    /// will now never consume, and a handler that returns without reading them
    /// is a handler that fires again immediately, forever.
    ///
    /// Cancelling releases the read source's hold on the descriptor, and the
    /// descriptor survives the ``flush(_:)`` below regardless: a cancellation
    /// handler is submitted to this queue rather than run inline, so it cannot
    /// overtake the block it was submitted from.
    private func refuse(_ connection: Connection) {
        connection.reader?.cancel()
        connection.reader = nil
        connection.inbound.removeAll()
        connection.closeAfterFlush = true
        flush(connection)
    }

    /// Cancels rather than suspends. A suspended `DispatchSource` that is then
    /// released traps, and the write source exists only while there are bytes
    /// waiting, so cancelling on empty is both the cheap path and the safe one.
    private func disarm(_ connection: Connection) {
        connection.writer?.cancel()
        connection.writer = nil
    }

    // MARK: Teardown

    /// Drops one connection's sources and lets the descriptor go with the last of
    /// them.
    ///
    /// **Neither source owns the close, because two of them share one
    /// descriptor.** GCD's contract is that a descriptor stays open until the
    /// cancellation handler of every source registered on it has run, and the
    /// write source is armed and disarmed on its own schedule, so cancelling it
    /// here and then closing from the read source's handler would meet the
    /// contract only by the accident that both handlers happen to target one
    /// serial queue. A closed-then-recycled descriptor is how that shape delivers
    /// an event on somebody else's file. ``DescriptorHandle`` counts instead: the
    /// last handler out closes, in whatever order they run.
    private func tearDown(_ connection: Connection, notify: Bool) {
        guard connection.isTornDown == false else { return }
        connection.isTornDown = true
        connections[connection.id] = nil

        disarm(connection)
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
        let handle: DescriptorHandle
        var reader: DispatchSourceRead?
        var writer: DispatchSourceWrite?
        var inbound: [UInt8] = []

        /// The write side's two bounds and the bytes they bound. A value type in
        /// the pure package, because what it decides is decidable without a
        /// descriptor and `make test` decides it there.
        var pressure = ConnectionBackpressure()

        var closeAfterFlush = false

        /// Whether the close already has a deadline, so a flush that stalls twice
        /// arms one and not two.
        var hasCloseDeadline = false

        var isTornDown = false

        var descriptor: Int32 { handle.descriptor }

        init(id: Int, descriptor: Int32) {
            self.id = id
            handle = DescriptorHandle(descriptor)
        }
    }

    /// One descriptor's lifetime, shared by every `DispatchSource` registered on
    /// it.
    ///
    /// **The close belongs to the last cancellation handler out, and to no
    /// particular source.** GCD requires the descriptor to stay open until every
    /// source on it has had its cancellation handler invoked, and a connection
    /// here carries two: a read source for its whole life and a write source that
    /// exists only while bytes are waiting. Naming one of them the owner meets the
    /// requirement only while the other happens to be cancelled first on the same
    /// queue, which is a scheduling accident and not a construction. So each
    /// source takes a hold before it is resumed and drops it from its own cancel
    /// handler, and the count decides.
    ///
    /// A separate object rather than a counter on ``Connection`` so the cancel
    /// handlers capture this and not the connection, which would put a retain
    /// cycle through the source the connection is holding.
    ///
    /// Confined to the channel queue like everything else: holds are taken there,
    /// and cancellation handlers are submitted there because that is every
    /// source's target queue.
    private final class DescriptorHandle {
        let descriptor: Int32
        private var holds = 0
        private var isClosed = false

        init(_ descriptor: Int32) {
            self.descriptor = descriptor
        }

        func hold() {
            holds += 1
        }

        func release() {
            holds -= 1
            guard holds <= 0, isClosed == false else { return }
            isClosed = true
            Darwin.close(descriptor)
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

    private static let newline = UInt8(0x0A)
}
