import Foundation
import ProjectAnchor
import Testing

@testable import PanePrompt

/// What a sidebar row click actually does, once the pane's anchor and working
/// directory are in the picture. `PromptPathTests` covers the lexical rule in
/// isolation; this covers the sequencing `AppDelegate.sendToPrompt` used to do by
/// hand: ``ProjectAnchor/Anchor/refusalRoot(of:)``, then ``PromptPath/resolve``,
/// then ``ProjectAnchor/Anchor/promptRoot(of:)``, plus the symlink resolution of
/// both directories that used to sit at the call site.
@Suite struct PromptDecisionTests {
    private func plainAnchor(_ url: URL) -> Anchor {
        Anchor(url: url, kind: .plain, source: .automatic)
    }

    private func repositoryAnchor(_ url: URL) -> Anchor {
        Anchor(url: url, kind: .repository, source: .automatic)
    }

    /// A plain anchor with a row a shell cannot hold: refused with its reason,
    /// never inert. The reason is what lets `showNotice` say something instead of
    /// nothing, which is the whole defect this sequencing exists to close.
    @Test func plainAnchorWithAnUnholdableRowRefusesWithItsReason() {
        let root = URL(filePath: "/repo", directoryHint: .isDirectory)
        let decision = PromptPath.decision(
            anchor: plainAnchor(root),
            repositoryRelativePath: [0x1B, 0x61], // ESC, 'a'
            workingDirectory: root
        )
        #expect(decision == .refuse(.controlScalar))
    }

    /// A plain anchor with a row a shell could hold: nothing is sent and nothing
    /// is refused, because `promptRoot` stays nil for a `.plain` anchor. A bare
    /// shell pane stays send-inert by the owner's ruling.
    @Test func plainAnchorWithAHoldableRowIsInert() {
        let root = URL(filePath: "/repo", directoryHint: .isDirectory)
        let decision = PromptPath.decision(
            anchor: plainAnchor(root),
            repositoryRelativePath: Array("src/main.swift".utf8),
            workingDirectory: root
        )
        #expect(decision == .inert)
    }

    /// A repository anchor with a row a shell could hold: sent, because
    /// `promptRoot` answers non-nil only for `.repository`.
    @Test func repositoryAnchorWithAHoldableRowSends() {
        let root = URL(filePath: "/repo", directoryHint: .isDirectory)
        let decision = PromptPath.decision(
            anchor: repositoryAnchor(root),
            repositoryRelativePath: Array("src/main.swift".utf8),
            workingDirectory: root
        )
        #expect(decision == .send(Array("src/main.swift ".utf8)))
    }

    /// The 2026-07-29 case: a repository under `/private` (here, `/private/tmp`,
    /// the same trap the fixture in `PromptPathTests` names for `/private/var`)
    /// with a kernel-spelled working directory. `ProcessWorkingDirectory` reports
    /// the kernel's `/private/...` spelling while the anchor's root has already
    /// had `/private` stripped by `resolvingSymlinksInPath()` inside
    /// `GitRepositoryLocator`. Without both sides put through the same resolution
    /// here, the two spellings share no prefix and every click sends an absolute
    /// path instead of a relative one. `decision` resolves both, so the send comes
    /// back relative.
    @Test func repositoryUnderPrivateVarWithKernelSpelledWorkingDirectoryRelativizes() throws {
        // `proc_pidinfo` reports the vnode path, `/private/tmp/...`, which is the
        // spelling `/tmp` is itself a symlink to. Built directly, rather than by
        // resolving `/tmp`, because `.resolvingSymlinksInPath()` leaves `/tmp`
        // itself alone on this toolchain and only strips `/private` off a path
        // that already carries it.
        let base = URL(filePath: "/private/tmp", directoryHint: .isDirectory)
            .appendingPathComponent("prompt-decision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // The kernel spelling: what `proc_pidinfo` reports.
        let kernelWorkingDirectory = base
        // The stripped spelling: what `GitRepositoryLocator` hands the anchor,
        // once `resolvingSymlinksInPath()` has already run on it once upstream,
        // stripping the leading `/private` because the stripped path exists.
        let strippedRoot = URL(
            filePath: base.resolvingSymlinksInPath().path(percentEncoded: false),
            directoryHint: .isDirectory
        )
        #expect(kernelWorkingDirectory.path(percentEncoded: false).hasPrefix("/private/tmp/"))
        #expect(!strippedRoot.path(percentEncoded: false).hasPrefix("/private/"))

        let decision = PromptPath.decision(
            anchor: repositoryAnchor(strippedRoot),
            repositoryRelativePath: Array("src/main.swift".utf8),
            workingDirectory: kernelWorkingDirectory
        )
        #expect(decision == .send(Array("src/main.swift ".utf8)))
    }

    /// A nil anchor: no root to resolve against at all, so `refusalRoot` answers
    /// nil first and nothing further runs.
    @Test func nilAnchorIsInert() {
        let decision = PromptPath.decision(
            anchor: nil,
            repositoryRelativePath: Array("src/main.swift".utf8),
            workingDirectory: nil
        )
        #expect(decision == .inert)
    }
}

