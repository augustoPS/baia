import Foundation
import Testing

@testable import GitWorkspace

/// The trees these tests build are the owner's workspace in miniature: `website`
/// holding four repositories, `lifetracker` holding none, `baia` holding worktrees
/// in both layouts.
@Suite final class ProjectDiscoveryTests {
    let fixture: DirectoryFixture

    init() throws {
        fixture = try DirectoryFixture()
    }

    /// Discovery over the fixture root with the shipping ignore set and the depth
    /// the real workspace needs.
    private func discovery(maxDepth: Int = 2) -> ProjectDiscovery {
        ProjectDiscovery(
            roots: [fixture.root],
            maxDepth: maxDepth,
            ignoredNames: ProjectDiscovery.defaultIgnoredNames
        )
    }

    /// A `worktrees:` closure that names nothing, for the tests about walking.
    private func noWorktrees(_: URL) -> [Worktree] { [] }

    @Test func findsARepositoryDirectlyUnderARoot() throws {
        try fixture.repository("baia")
        let projects = discovery().discover(worktrees: noWorktrees)
        #expect(projects.map(\.relativePath) == ["baia"])
        #expect(projects.first?.kind == .repository)
        #expect(projects.first?.displayName == "baia")
    }

    @Test func keepsWalkingSiblingsPastARepository() throws {
        // `website` is not a repository while all four sites under it are, so a
        // walk that stopped at the first hit would find one site and abandon the
        // rest. The relative paths are what disambiguate them in the palette.
        try fixture.repository("website/pasqualo.to")
        try fixture.repository("website/shop")
        try fixture.repository("website/admin")
        try fixture.repository("website/finances")

        let projects = discovery().discover(worktrees: noWorktrees)

        #expect(projects.map(\.relativePath) == [
            "website/admin",
            "website/finances",
            "website/pasqualo.to",
            "website/shop",
        ])
    }

    @Test func doesNotOfferAContainerOfRepositories() throws {
        // The mirror of offersADirectoryHoldingNoRepository: same shape, same
        // depth, one repository underneath instead of none. Either test alone
        // passes whichever way the container rule goes. An entry for `website`
        // would open the container while reading like one of the sites.
        try fixture.repository("website/shop")
        let projects = discovery().discover(worktrees: noWorktrees)
        #expect(!projects.map(\.relativePath).contains("website"))
    }

    @Test func offersADirectoryHoldingNoRepository() throws {
        // `lifetracker` on this machine has no `.git` at all and is still a project
        // the owner switches to. Assuming every child is a repository drops it
        // entirely.
        try fixture.directory("lifetracker/Sources/LifeTracker")
        let projects = discovery().discover(worktrees: noWorktrees)
        #expect(projects.map(\.relativePath) == ["lifetracker"])
        #expect(projects.first?.kind == .directory)
    }

    @Test func doesNotOfferTheContentsOfADirectoryProject() throws {
        // `lifetracker/Sources` is at the same depth as `website/shop` and must not
        // be offered, which is what confines the `.directory` answer to a root's
        // own children. Emitting one row per source folder makes the palette
        // useless on the first project without a repository.
        try fixture.directory("lifetracker/Sources")
        try fixture.directory("lifetracker/Tests")
        let projects = discovery().discover(worktrees: noWorktrees)
        #expect(projects.map(\.relativePath) == ["lifetracker"])
    }

    @Test func doesNotDescendIntoARepository() throws {
        // A vendored checkout inside a repository belongs to it. Offering it as a
        // sibling puts two rows in the palette that open the same work.
        try fixture.repository("baia")
        try fixture.repository("baia/vendor/libghostty-spm")
        let projects = discovery().discover(worktrees: noWorktrees)
        #expect(projects.map(\.relativePath) == ["baia"])
    }

    @Test func stopsAtMaxDepth() throws {
        // Depth 1 finds a root's own children only. The pair with the default of 2
        // is what pins that the parameter does anything: a walk that ignored it
        // would find the nested repository here too.
        try fixture.repository("website/shop")
        let projects = discovery(maxDepth: 1).discover(worktrees: noWorktrees)
        #expect(projects.map(\.relativePath) == ["website"])
        #expect(projects.first?.kind == .directory)
    }

    @Test func findsARepositoryThreeDeepWhenTheDepthAllowsIt() throws {
        try fixture.repository("skills/plugins/wrap-up")
        let projects = discovery(maxDepth: 3).discover(worktrees: noWorktrees)
        #expect(projects.map(\.relativePath) == ["skills/plugins/wrap-up"])
    }

    @Test func neverWalksIntoAnIgnoredName() throws {
        // `node_modules` in one Astro site holds more directories than the rest of
        // the workspace put together, and a repository vendored inside one is not a
        // project. This is the visible half of the ignore rule; the hidden-name
        // rule covers `.build` and friends on its own.
        try fixture.repository("shop/node_modules/some-package")
        let projects = discovery().discover(worktrees: noWorktrees)
        #expect(projects.map(\.relativePath) == ["shop"])
    }

    @Test func neverWalksIntoAHiddenDirectory() throws {
        // A `.claude/worktrees/agent-<hex>` copy holds a full `.git` and would be
        // offered as a repository of its own. Walking those copies is what made an
        // admin vitest run report three times its real test count.
        try fixture.repository("baia/.claude/worktrees/agent-4f21")
        try fixture.repository("baia/.worktrees/feature-0725-1200")
        let projects = discovery().discover(worktrees: noWorktrees)
        #expect(projects.map(\.relativePath) == ["baia"])
    }

    @Test func defaultIgnoredNamesCoversTheDirectoriesThatBlowUpAWalk() {
        // Named individually rather than by count, so adding an entry does not
        // require editing this test while removing one does.
        for name in [
            "node_modules", ".build", "DerivedData", ".git", ".claude", ".worktrees",
            "photos", "dist", ".next", ".astro", "Pods", ".venv", "__pycache__", ".swiftpm",
        ] {
            #expect(ProjectDiscovery.defaultIgnoredNames.contains(name))
        }
    }

    @Test func namesEachWorktreeAfterItsRepository() throws {
        // The recorded pain point is four concurrent panes carrying no identity:
        // `agent-4f21` alone says nothing about which project it is rewriting.
        try fixture.repository("baia")
        let projects = discovery().discover { root in
            [
                Worktree(url: root, branch: "main", isMain: true),
                Worktree(
                    url: root.appending(path: ".claude/worktrees/agent-4f21"),
                    branch: "worktree-agent-4f21"
                ),
            ]
        }
        #expect(projects.map(\.displayName) == ["baia", "baia/agent-4f21"])
        #expect(projects.last?.kind == .worktree(ofRepositoryNamed: "baia"))
        #expect(projects.last?.url == fixture.directoryURL("baia/.claude/worktrees/agent-4f21"))
        #expect(projects.first?.url == fixture.directoryURL("baia"))
    }

    @Test func rendersBothWorktreeLayouts() throws {
        // Both are in use on this machine, and neither directory is ever walked
        // into: the closure is what supplies them, which is why a worktree that
        // exists only in git's registry still gets a row.
        let repository = try fixture.repository("baia")
        let projects = discovery().discover { root in
            [
                Worktree(url: root, isMain: true),
                Worktree(url: root.appending(path: ".worktrees/feature-0725-1200")),
                Worktree(url: root.appending(path: ".claude/worktrees/agent-4f21")),
            ]
        }
        #expect(projects.map(\.relativePath) == [
            "baia",
            "baia/.worktrees/feature-0725-1200",
            "baia/.claude/worktrees/agent-4f21",
        ])
        #expect(!FileManager.default.fileExists(
            atPath: repository.appending(path: ".worktrees").path(percentEncoded: false)
        ))
    }

    @Test func doesNotEmitTheMainWorktreeTwice() throws {
        // `git worktree list` puts the main working tree first, and the walk has
        // already emitted it. Trusting the flag alone is not enough for a bare
        // repository, whose first stanza is the bare directory, so the path is
        // compared as well: here the closure lies about `isMain` and the repository
        // still appears once.
        try fixture.repository("baia")
        let projects = discovery().discover { root in [Worktree(url: root, isMain: false)] }
        #expect(projects.map(\.relativePath) == ["baia"])
    }

    @Test func offersAWorktreeLivingOutsideEveryRootByItsFullPath() throws {
        // `git worktree add` accepts any destination. Prefix arithmetic that
        // assumed the root would hand back a suffix of an unrelated path, so the
        // palette would show `Projects/baia` for something living in /tmp.
        try fixture.repository("baia")
        let projects = discovery().discover { root in
            [
                Worktree(url: root, isMain: true),
                Worktree(url: URL(filePath: "/tmp/detached-spike", directoryHint: .isDirectory)),
            ]
        }
        let outside = projects.last?.relativePath ?? ""
        #expect(outside.hasPrefix("/"))
        #expect(outside.hasSuffix("/detached-spike"))
    }

    @Test func discoversTheRootItselfWhenTheRootIsARepository() throws {
        // Pointing this at a single repository otherwise finds its Packages and
        // Sources folders and never the repository, which reads as discovery being
        // broken rather than as a misconfigured root. The relative path falls back
        // to the last component, because the literal answer is the empty string and
        // an unnamed palette row cannot be selected on purpose.
        let repository = try fixture.repository("baia")
        try fixture.directory("baia/Packages/GitWorkspace")
        let projects = ProjectDiscovery(
            roots: [repository],
            maxDepth: 2,
            ignoredNames: ProjectDiscovery.defaultIgnoredNames
        ).discover(worktrees: noWorktrees)
        #expect(projects.map(\.relativePath) == ["baia"])
        #expect(projects.first?.kind == .repository)
    }

    @Test func emitsEachProjectOnceWhenTwoRootsOverlap() throws {
        // `~/Projects` and `~/Projects/website` both reach `website/shop`. The
        // duplicate would also cost a second `git worktree list` process per
        // repository, which is why the check happens before the closure is called.
        try fixture.repository("website/shop")
        var worktreeCalls = 0
        let projects = ProjectDiscovery(
            roots: [fixture.root, fixture.root.appending(path: "website")],
            maxDepth: 2,
            ignoredNames: ProjectDiscovery.defaultIgnoredNames
        ).discover { _ in
            worktreeCalls += 1
            return []
        }
        #expect(projects.count == 1)
        #expect(worktreeCalls == 1)
    }

    @Test func findsNothingUnderARootThatIsNotThere() {
        // A root the owner moved or deleted. The enumerator returns nil for it, and
        // an unguarded walk would take the whole discovery down with it rather than
        // returning the projects under the other roots.
        let projects = ProjectDiscovery(
            roots: [fixture.root.appending(path: "gone")],
            maxDepth: 2,
            ignoredNames: ProjectDiscovery.defaultIgnoredNames
        ).discover(worktrees: noWorktrees)
        #expect(projects.isEmpty)
    }

    @Test func ignoresFilesSittingBesideTheProjects() throws {
        // `~/Projects` holds `CLAUDE.md` and a `.gitignore`. A palette row for a
        // markdown file cannot be opened as a pane.
        try fixture.file("CLAUDE.md", contents: "# CLAUDE.md\n")
        try fixture.repository("baia")
        let projects = discovery().discover(worktrees: noWorktrees)
        #expect(projects.map(\.relativePath) == ["baia"])
    }

    @Test func treatsAWorktreeCheckoutAsARepositoryWhenItIsWalkedInto() throws {
        // A worktree the owner keeps outside the repository holds `.git` as a file,
        // not a directory, and the walk has to claim it: `fileExists` covers both
        // shapes in one call, and testing for a directory would miss every worktree
        // and every submodule kept beside its project.
        try fixture.worktree("baia-spike", pointingAt: "/somewhere/.git/worktrees/spike")
        let projects = discovery().discover(worktrees: noWorktrees)
        #expect(projects.map(\.kind) == [.repository])
    }
}
