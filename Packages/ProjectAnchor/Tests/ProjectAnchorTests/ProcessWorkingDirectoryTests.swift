import Darwin
import Foundation
import Testing

@testable import ProjectAnchor

@Suite struct ProcessWorkingDirectoryTests {
    @Test func readsItsOwnWorkingDirectory() {
        // getcwd (behind currentDirectoryPath) and proc_pidinfo both report the
        // physical vnode path, so no normalization is wanted here. Resolving
        // would strip a leading /private and break the comparison for a checkout
        // under a temporary directory. The directory hint stays, because that is
        // what url(ofProcess:) hands back and it is what puts the trailing slash
        // on the rendered path.
        let expected = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
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
