import Foundation
import PaneCLI

/// stdout, stderr, and the one read of stdin the protocol allows.
///
/// Split so the rule is visible in one place: **results go to stdout and
/// everything else goes to stderr**. A `baia publish` piped into another command
/// must carry the ticket and nothing else, and a `baia recv` piped into a file
/// must carry message bodies and not a note about a drop counter.
enum StandardStreams {
    /// A result line. The only thing a pipe downstream should ever see.
    static func out(_ line: String) {
        write(line + "\n", to: FileHandle.standardOutput)
    }

    /// A note, a warning, or a failure. Never parsed by anything: the exit
    /// status is what a script branches on.
    static func err(_ line: String) {
        write(line + "\n", to: FileHandle.standardError)
    }

    /// A rendered result, replayed in the order ``Rendering`` decided.
    ///
    /// In order rather than stdout first, because a note explains the line it
    /// sits next to: `publish` prints the ticket and then says what it admits,
    /// and `peers` says there are none before printing none.
    static func write(_ lines: [RenderedLine]) {
        for line in lines {
            switch line.stream {
            case .out:
                out(line.text)
            case .err:
                err(line.text)
            }
        }
    }

    /// Everything on stdin, as bytes.
    ///
    /// The rendezvous ticket and a `--stdin` message body both come through
    /// here, which is the whole point: a ticket passed as `baia connect <TICKET>`
    /// would be readable by every same-uid process for as long as the process
    /// lived, and a pane running a `ps` loop is exactly the adversary this
    /// channel bounds.
    static func readAllOfStdin() -> Data {
        FileHandle.standardInput.readDataToEndOfFile()
    }

    private static func write(_ text: String, to handle: FileHandle) {
        handle.write(Data(text.utf8))
    }
}
