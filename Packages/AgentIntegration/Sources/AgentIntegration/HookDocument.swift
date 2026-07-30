import Foundation

/// One hook baia wants installed: which event, under which matcher, running what.
///
/// The caller decides the set. This file decides only how a set is merged into a
/// document somebody else owns, which is why the events are strings here rather
/// than an enum: the merge has no opinion about which of Claude Code's events are
/// worth listening to, and one that gains a new event should not have to change
/// this type.
public struct HookEntry: Sendable, Equatable {
    public var event: String

    /// The `matcher` the entry sits under, or nil for an entry that takes every
    /// invocation of its event. Nil omits the key rather than writing an empty
    /// string, which Claude Code would read as a pattern.
    public var matcher: String?

    public var command: String

    public init(event: String, matcher: String? = nil, command: String) {
        self.event = event
        self.matcher = matcher
        self.command = command
    }
}

/// Merging baia's hooks into `~/.claude/settings.json`, and taking them back out.
///
/// **Ownership is the command path and nothing else.** A hook object belongs to
/// baia if and only if its `command` names the managed script. That is the
/// substitute for herdr's `# >>>` and `# <<<` markers, which cannot go in a
/// format with no comments, and it is exact rather than a guess because the path
/// belongs to baia.
///
/// Everything here is pure and every rule below is tested, because this is the
/// one part of baia that can silently destroy something the owner wrote by hand.
public enum HookDocument {
    private static let hooksKey = "hooks"
    private static let matcherKey = "matcher"
    private static let entryHooksKey = "hooks"
    private static let commandKey = "command"
    private static let typeKey = "type"

    /// Whether a hook object is one baia wrote.
    static func isOwned(_ hook: JSON, by script: String) -> Bool {
        guard case let .object(hook) = hook, case let .string(command)? = hook[commandKey] else {
            return false
        }
        return command.contains(script)
    }

    /// Adds baia's hooks, replacing any it already owns.
    ///
    /// **Returns nil rather than guessing.** A document that is not an object, a
    /// `hooks` value that is not one, or an event that is not an array is
    /// somebody's file in a shape this code does not understand, and an installer
    /// that presses on through that is how a config gets eaten.
    ///
    /// Replacement happens in place, so a second run and an upgrade both leave the
    /// owner's diff at one line rather than moving baia's hook to the end of an
    /// array it was in the middle of.
    public static func install(
        _ entries: [HookEntry],
        ownedBy script: String,
        into document: JSON
    ) -> JSON? {
        guard case var .object(root) = document else { return nil }

        var hooks: JSONObject
        switch root[hooksKey] {
        case nil: hooks = JSONObject()
        case let .object(existing)?: hooks = existing
        default: return nil
        }

        // Anything baia owns that the caller no longer wants goes first, so an
        // upgrade that moved a hook to a different matcher does not leave the old
        // one behind.
        let wanted = Set(entries.map { "\($0.event)\u{0}\($0.matcher ?? "")" })
        for event in hooks.keys {
            guard case let .array(list)? = hooks[event] else { return nil }
            var kept: [JSON] = []
            for entry in list {
                guard case let .object(entryObject) = entry else { return nil }
                let matcher: String?
                switch entryObject[matcherKey] {
                case nil: matcher = nil
                case let .string(value)?: matcher = value
                default: return nil
                }
                if wanted.contains("\(event)\u{0}\(matcher ?? "")") {
                    kept.append(entry)
                    continue
                }
                guard let stripped = removingOwned(from: entry, by: script) else { return nil }
                // An entry that is empty only because baia's hook left is baia's
                // own and goes. One that was already empty is the owner's and
                // stays: an empty array somebody wrote is a statement.
                if let stripped { kept.append(stripped) }
            }
            hooks[event] = .array(kept)
        }

        for entry in entries {
            guard let updated = upsert(entry, ownedBy: script, into: hooks[entry.event]) else {
                return nil
            }
            hooks[entry.event] = updated
        }

        // An event left with nothing after the sweep above, which can only happen
        // when baia created it and no longer wants it.
        for event in hooks.keys {
            if case let .array(list)? = hooks[event], list.isEmpty {
                hooks[event] = nil
            }
        }

        root[hooksKey] = .object(hooks)
        return .object(root)
    }

    /// Removes every hook baia owns, unwinding containers only as far as baia
    /// created them.
    ///
    /// Nil on a shape this code does not understand, matching ``install(_:ownedBy:into:)``:
    /// a document too strange to install into is too strange to edit at all.
    public static func uninstall(ownedBy script: String, from document: JSON) -> JSON? {
        guard case var .object(root) = document else { return nil }
        switch root[hooksKey] {
        case nil: return document
        case let .object(existing)?:
            var hooks = existing
            for event in hooks.keys {
                guard case let .array(list)? = hooks[event] else { return nil }
                var kept: [JSON] = []
                for entry in list {
                    guard let stripped = removingOwned(from: entry, by: script) else { return nil }
                    if let stripped { kept.append(stripped) }
                }
                // Same rule as install: an event array emptied by baia's departure
                // was baia's; one the owner left empty stays empty.
                if kept.isEmpty, list.isEmpty == false {
                    hooks[event] = nil
                } else {
                    hooks[event] = .array(kept)
                }
            }
            // And the `hooks` key itself, if baia is the reason it is empty.
            if hooks.isEmpty, existing.isEmpty == false {
                root[hooksKey] = nil
            } else {
                root[hooksKey] = .object(hooks)
            }
            return .object(root)
        default:
            return nil
        }
    }

    /// One entry with baia's hooks taken out.
    ///
    /// Returns `.some(nil)` for an entry that should disappear, `.some(entry)` for
    /// one that should stay, and nil for a shape that cannot be read.
    private static func removingOwned(from entry: JSON, by script: String) -> JSON?? {
        guard case var .object(object) = entry else { return nil }
        guard case let .array(hooks)? = object[entryHooksKey] else {
            // An entry with no hooks array is not baia's and is not ours to
            // reshape. Kept exactly as found.
            return .some(entry)
        }
        let kept = hooks.filter { isOwned($0, by: script) == false }
        guard kept.count != hooks.count else { return .some(entry) }
        if kept.isEmpty {
            // Baia was the only occupant, so baia created this entry.
            return .some(nil)
        }
        object[entryHooksKey] = .array(kept)
        return .some(.object(object))
    }

    /// Finds the entry for a matcher and puts baia's hook in it, or creates one.
    private static func upsert(_ entry: HookEntry, ownedBy script: String, into event: JSON?) -> JSON? {
        var list: [JSON]
        switch event {
        case nil: list = []
        case let .array(existing)?: list = existing
        default: return nil
        }

        let hook = JSON.object(JSONObject([
            (typeKey, .string("command")),
            (commandKey, .string(entry.command)),
        ]))

        for (index, candidate) in list.enumerated() {
            guard case var .object(object) = candidate else { return nil }
            let matcher: String?
            switch object[matcherKey] {
            case nil: matcher = nil
            case let .string(value)?: matcher = value
            default: return nil
            }
            guard matcher == entry.matcher else { continue }

            var hooks: [JSON]
            switch object[entryHooksKey] {
            case nil: hooks = []
            case let .array(existing)?: hooks = existing
            default: return nil
            }
            // In place where baia already sits, so an upgrade does not move it
            // past hooks the owner wrote after it.
            if let position = hooks.firstIndex(where: { isOwned($0, by: script) }) {
                hooks[position] = hook
                // A second baia hook in one entry can only come from a hand edit
                // or an older bug; keep the first and drop the rest.
                hooks = hooks.enumerated().filter { offset, value in
                    offset == position || isOwned(value, by: script) == false
                }.map(\.element)
            } else {
                hooks.append(hook)
            }
            object[entryHooksKey] = .array(hooks)
            list[index] = .object(object)
            return .array(list)
        }

        var created = JSONObject()
        if let matcher = entry.matcher { created[matcherKey] = .string(matcher) }
        created[entryHooksKey] = .array([hook])
        list.append(.object(created))
        return .array(list)
    }
}
