import Darwin
import Foundation
import PaneControl
import WorkspaceLayout

/// Production ControlTransport + ControlClient: a slow reader whose first
/// valid frame is still only partly in the kernel when eviction runs, a second
/// client that is answered while that reader is held, and socket cleanup by
/// shutdown rather than by the probe unlinking first.
@main
enum ControlBackpressureProbe {
    static func main() throws {
        let directory = try uniqueDirectory()
        let socketPath = directory + "/control.sock"
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let transport = ControlTransport(path: socketPath)
        let large = try maxValidFrame()
        let filler = Data(repeating: UInt8(ascii: "x"), count: ControlWire.maxFrameBytes - 1) + Data([0x0A])
        guard filler.count == ControlWire.maxFrameBytes else {
            throw ProbeError("filler is not a full invalid frame")
        }
        guard let small = ControlWire.encodeResponse(.success(ControlResult(pane: "ok"))) else {
            throw ProbeError("could not encode small frame")
        }
        guard let request = ControlWire.encodeRequest(ControlRequest(token: "probe", verb: .whoami)) else {
            throw ProbeError("could not encode request")
        }

        let firstID = Locked<Int?>(nil)
        let accepted = Locked(0)
        let closed = Locked(0)
        let outcome: ControlTransport.BindOutcome = transport.bind(
            handlers: ControlTransportHandlers(
                accepted: { id in
                    accepted.mutate { $0 += 1 }
                    if firstID.value == nil { firstID.value = id }
                },
                line: { id, _ in
                    if id == firstID.value {
                        transport.send(large, to: id)
                        for _ in 0 ..< 8 { transport.send(filler, to: id) }
                    } else {
                        transport.send(small, to: id)
                    }
                },
                oversized: { _ in },
                closed: { _ in closed.mutate { $0 += 1 } }
            )
        )
        switch outcome {
        case .bound:
            break
        case .ownedByAnotherInstance:
            throw ProbeError("bind failed: socket already owned")
        case let .failed(reason):
            throw ProbeError("bind failed: \(reason)")
        }

        let slow = try connectSlowClient(path: socketPath, request: request)
        defer { Darwin.close(slow) }

        var received = try readBounded(from: slow, limit: 2048, timeout: 2)
        guard received.isEmpty == false, received.contains(UInt8(0x0A)) == false else {
            throw ProbeError("slow client prefix was empty or already a complete line; bytes=\(received.count)")
        }
        let buffered = received.count + peekAvailable(on: slow, limit: large.count)
        guard buffered > 0, buffered < large.count else {
            throw ProbeError(
                "eviction did not intersect a partial first frame; visible=\(buffered) frame=\(large.count)"
            )
        }

        let timely = ControlClient(socketPath: socketPath).exchange(
            ControlRequest(token: "probe", verb: .whoami),
            readTimeoutSeconds: 5
        )
        switch timely {
        case let .answered(response):
            guard response.result?.pane == "ok" else {
                throw ProbeError("timely client got \(String(describing: response.result))")
            }
        case let .broken(reason):
            throw ProbeError("timely client failed: \(reason)")
        case .closedWithoutAnswer:
            throw ProbeError("timely client closed without an answer")
        }
        guard received.contains(UInt8(0x0A)) == false else {
            throw ProbeError("slow client finished the first frame before the timely client ran")
        }

        let lines = try readLines(from: slow, want: 2, timeout: 8, received: &received)
        guard let first = ControlWire.decodeResponse(lines[0]), first.ok,
              first.result?.pane?.count == largePaneCount(in: large)
        else {
            let classification = ControlWire.classifyUndecodableResponse(lines[0])
            throw ProbeError(
                "slow client first line was not the completed production frame; classify=\(classification) bytes=\(lines[0].count)"
            )
        }
        if first.result?.pane?.contains("different build") == true {
            throw ProbeError("slow client decoded a wrong-build payload")
        }
        guard ControlWire.decodeResponse(lines[1])?.error?.code == .refused else {
            throw ProbeError("slow client second line was not the refusal")
        }

        let closedDeadline = Date().addingTimeInterval(2)
        while closed.value < 2, Date() < closedDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard closed.value >= 2 else {
            throw ProbeError("automatic cleanup did not close both connections before shutdown; closed=\(closed.value)")
        }
        guard access(socketPath, F_OK) == 0 else {
            throw ProbeError("socket file vanished before shutdown")
        }

        transport.shutdown()
        guard access(socketPath, F_OK) != 0 else {
            throw ProbeError("socket file still present after shutdown")
        }
        print(
            "PASS control-backpressure: partial first frame \(buffered)/\(large.count), "
                + "refusal, timely second client, closed=\(closed.value) before shutdown"
        )
    }

    private static func uniqueDirectory() throws -> String {
        var bytes = [CChar]("/tmp/baia-q05.XXXXXX".utf8CString)
        guard mkdtemp(&bytes) != nil else {
            throw ProbeError("could not create unique directory")
        }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func maxValidFrame() throws -> Data {
        var low = 1
        var high = ControlWire.maxFrameBytes
        var best: Data?
        while low <= high {
            let mid = (low + high) / 2
            guard let data = ControlWire.encodeResponse(
                .success(ControlResult(pane: String(repeating: "a", count: mid)))
            ) else {
                high = mid - 1
                continue
            }
            if data.count <= ControlWire.maxFrameBytes {
                best = data
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let best, best.count > 128 * 1024 else {
            throw ProbeError("could not build a first frame larger than 128 KiB")
        }
        return best
    }

    private static func largePaneCount(in frame: Data) -> Int {
        ControlWire.decodeResponse(frame)?.result?.pane?.count ?? -1
    }

    private static func connectSlowClient(path: String, request: Data) throws -> Int32 {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw ProbeError("socket path too long") }
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (offset, byte) in bytes.enumerated() { destination[offset] = CChar(bitPattern: byte) }
                destination[bytes.count] = 0
            }
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ProbeError("slow client socket") }
        var on: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var rcv = 2048
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &rcv, socklen_t(MemoryLayout<Int32>.size))
        setTimeout(descriptor, seconds: 1)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(descriptor)
            throw ProbeError("slow client connect \(errno)")
        }
        var sent = 0
        let requestBytes = [UInt8](request)
        let writeDeadline = Date().addingTimeInterval(5)
        while sent < requestBytes.count {
            if Date() > writeDeadline {
                Darwin.close(descriptor)
                throw ProbeError("slow client write timed out")
            }
            let written = requestBytes.withUnsafeBufferPointer { buffer in
                Darwin.write(descriptor, buffer.baseAddress! + sent, requestBytes.count - sent)
            }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else {
                Darwin.close(descriptor)
                throw ProbeError("slow client write")
            }
            sent += written
        }
        return descriptor
    }

    private static func peekAvailable(on descriptor: Int32, limit: Int) -> Int {
        var chunk = [UInt8](repeating: 0, count: limit)
        let count = chunk.withUnsafeMutableBufferPointer { buffer in
            Darwin.recv(descriptor, buffer.baseAddress, limit, Int32(MSG_PEEK))
        }
        return count > 0 ? Int(count) : 0
    }

    private static func readBounded(from descriptor: Int32, limit: Int, timeout: TimeInterval) throws -> Data {
        setTimeout(descriptor, seconds: 1)
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: min(limit, 512))
        let deadline = Date().addingTimeInterval(timeout)
        while received.count < limit, Date() < deadline {
            let want = min(chunk.count, limit - received.count)
            let count = chunk.withUnsafeMutableBufferPointer { buffer in
                Darwin.read(descriptor, buffer.baseAddress!, want)
            }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK { continue }
                throw ProbeError("slow client prefix read: \(String(cString: strerror(code)))")
            }
            if count == 0 { break }
            received.append(contentsOf: chunk[0 ..< count])
        }
        return received
    }

    private static func readLines(
        from descriptor: Int32,
        want: Int,
        timeout: TimeInterval,
        received: inout Data
    ) throws -> [Data] {
        setTimeout(descriptor, seconds: 1)
        var lines: [Data] = []
        var chunk = [UInt8](repeating: 0, count: 4 * 1024)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            while let end = received.firstIndex(of: UInt8(0x0A)), lines.count < want {
                lines.append(Data(received[received.startIndex ... end]))
                received.removeSubrange(received.startIndex ... end)
            }
            if lines.count == want { return lines }
            if received.count > ControlWire.maxFrameBytes {
                throw ProbeError("slow client read passed the frame cap with no newline")
            }
            if Date() >= deadline { break }
            let count = chunk.withUnsafeMutableBufferPointer { buffer in
                Darwin.read(descriptor, buffer.baseAddress!, buffer.count)
            }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK { continue }
                throw ProbeError("slow client read: \(String(cString: strerror(code)))")
            }
            if count == 0 { break }
            received.append(contentsOf: chunk[0 ..< count])
        }
        throw ProbeError(
            "slow client expected \(want) lines and got \(lines.count) leftover=\(received.count)"
        )
    }

    private static func setTimeout(_ descriptor: Int32, seconds: Int) {
        var window = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &window,
            socklen_t(MemoryLayout<timeval>.size)
        )
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &window,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ stored: Value) { self.stored = stored }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&stored)
    }
}

private struct ProbeError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
