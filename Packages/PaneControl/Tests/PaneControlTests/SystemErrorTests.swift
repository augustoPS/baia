import Darwin
import Testing

@testable import PaneControl

/// A `strerror` wrapper, so ``ControlTransport``'s socket failures can name the
/// errno rather than the number.
///
/// The argument is an errno value rather than a descriptor, so nothing about it
/// needs the app target: it belongs beside the wire types that already
/// translate raw C answers into something a caller can print.
@Suite struct SystemErrorTests {
    @Test func namesAKnownErrno() {
        #expect(SystemError.reason(EEXIST) == String(cString: strerror(EEXIST)))
    }

    @Test func matchesStrerrorForAnyCode() {
        for code: Int32 in [0, EACCES, ENOTDIR, EINVAL] {
            #expect(SystemError.reason(code) == String(cString: strerror(code)))
        }
    }
}
