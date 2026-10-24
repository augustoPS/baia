import Foundation
import Testing

@testable import PanePrompt

@Suite struct TerminalFileDropTests {
    private func send(_ urls: [URL]) -> String? {
        guard case let .send(bytes) = TerminalFileDrop.resolve(fileURLs: urls) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test func sendsAbsolutePathsInDropOrderWithOneTrailingSpace() {
        #expect(send([
            URL(fileURLWithPath: "/tmp/first.png"),
            URL(fileURLWithPath: "/tmp/second.txt"),
        ]) == "/tmp/first.png /tmp/second.txt ")
    }

    @Test func quotesShellSyntaxWithoutExecutingOrSubmittingIt() {
        #expect(send([URL(fileURLWithPath: "/tmp/a b'\"$`é.png")])
            == "'/tmp/a b'\\''\"$`é.png' ")
    }

    @Test func decodesURLPathEscapesExactlyOnce() {
        #expect(send([URL(string: "file:///tmp/a%20b%2520.png")!]) == "'/tmp/a b%20.png' ")
        #expect(send([URL(fileURLWithPath: "/tmp/a?#.png")]) == "'/tmp/a?#.png' ")
    }

    @Test func acceptsLocalhostButRefusesOtherAuthorities() {
        #expect(send([URL(string: "file://localhost/tmp/image.png")!]) == "/tmp/image.png ")
        #expect(send([URL(string: "file://LOCALHOST/tmp/image.png")!]) == "/tmp/image.png ")
        for address in [
            "file://other-host/tmp/image.png", "file://user@localhost/tmp/image.png",
            "file://localhost:123/tmp/image.png", "https://localhost/tmp/image.png",
            "file:///tmp/image.png?query", "file:///tmp/image.png#fragment",
            "file:relative.png",
            "file:///tmp/a%00.png", "file:///tmp/a%2Fb.png", "file:///tmp/caf%E9.png",
        ] {
            #expect(TerminalFileDrop.resolve(fileURLs: [URL(string: address)!]) == nil)
        }
    }

    @Test func refusesControlScalarsWithoutReturningAPartialPayload() {
        for control in ["\n", "\r", "\t", "\u{1b}", "\u{7f}", "\u{85}"] {
            #expect(TerminalFileDrop.resolve(fileURLs: [
                URL(fileURLWithPath: "/tmp/good.png"),
                URL(fileURLWithPath: "/tmp/bad\(control).png"),
            ]) == .refuse(.controlScalar))
        }
    }

    @Test func rejectsAMixedLocalAndRemoteDropAsAWhole() {
        #expect(TerminalFileDrop.resolve(fileURLs: [
            URL(fileURLWithPath: "/tmp/good.png"),
            URL(string: "https://example.com/image.png")!,
        ]) == nil)
    }

    @Test func refusesAnEmptyDrop() {
        #expect(TerminalFileDrop.resolve(fileURLs: []) == .refuse(.emptyPath))
    }
}
