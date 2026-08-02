import Foundation
import PaneControl

extension PaneTree {
    /// One document node, as a tree of fresh panes.
    ///
    /// **Fresh ids on every apply**, which is what makes a layout a template: the
    /// document holds none, so applying the same file twice opens two independent
    /// windows rather than two claims on one set of panes.
    ///
    /// A directory that is not a directory becomes nil, and a nil opens at the
    /// default. That is the rule `SessionStore.reconciled` follows for a restore,
    /// except that this drops the *directory* and never the pane: the owner asked
    /// for five panes, and answering with four because one repository moved is a
    /// worse answer than five with one of them at home.
    public static func build(
        _ node: ControlLayoutNode,
        createdBy: PaneID,
        into states: inout [PaneState]
    ) -> PaneTree {
        switch node {
        case let .pane(cwd):
            let id = PaneID()
            states.append(
                PaneState(
                    id: id,
                    workingDirectory: cwd.flatMap(Self.existingDirectory),
                    pinnedDirectory: nil,
                    createdBy: createdBy
                )
            )
            return .leaf(id)
        case let .split(axis, ratio, first, second):
            return .split(
                axis: axis == .vertical ? .vertical : .horizontal,
                ratio: ControlLayout.clampedRatio(ratio),
                first: build(first, createdBy: createdBy, into: &states),
                second: build(second, createdBy: createdBy, into: &states)
            )
        }
    }

    /// `path` itself when it names a directory that exists, nil otherwise.
    ///
    /// The rule ``build(_:createdBy:into:)`` applies to a document's `cwd`: a
    /// directory that is not a directory becomes nil, and a nil opens at the
    /// default rather than failing the whole apply.
    static func existingDirectory(_ path: String) -> String? {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue ? path : nil
    }
}
