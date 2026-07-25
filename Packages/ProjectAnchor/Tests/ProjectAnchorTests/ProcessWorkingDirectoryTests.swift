import Darwin
import Foundation
import Testing

@testable import ProjectAnchor

@Suite struct ProcessWorkingDirectoryTests {
    @Test func readsItsOwnWorkingDirectory() {
        // proc_pidinfo returns the vnode path, which is symlink-resolved, so the
        // expectation has to be resolved too (/var vs /private/var). It also has
        // to be a directory URL, because that is what url(ofProcess:) hands back
        // and the hint is what puts the trailing slash on the rendered path.
        let expected = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
            .path(percentEncoded: false)

        let mine = ProcessWorkingDirectory.url(ofProcess: getpid())

        #expect(mine?.path(percentEncoded: false) == expected)
    }

    @Test func returnsNilForAnImpossiblePid() {
        #expect(ProcessWorkingDirectory.url(ofProcess: pid_t(-1)) == nil)
    }

    @Test func returnsNilForAProcessOwnedByAnotherUser() {
        // launchd runs as root and proc_pidinfo refuses cross-user inspection.
        // This is why the pane's shell has to run as the same user, which it
        // does: Ghostty spawns it through `login -flp`, which drops root.
        #expect(ProcessWorkingDirectory.url(ofProcess: pid_t(1)) == nil)
    }
}
