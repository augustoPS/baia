import Foundation
import Testing

@testable import PaneControl

/// Rule 2's invariant, held by a test rather than by everybody remembering it:
/// no capability value ever appears in a file, in argv, or in a response body.
///
/// **One bounded exception, allowed here by name and by nothing else.**
/// ``ControlResult/rendezvous`` carries the admission ticket back to the pane
/// that published it, because a ticket the publisher cannot read is a ticket it
/// cannot hand to anyone. Every other field named or typed like a capability
/// fails, and so does a *rename* of this one: the allowance is asserted to have
/// been used exactly once, at exactly that path, so moving the ticket to a field
/// called something else fails here even if the new name reads as innocent.
///
/// An unannounced exception inside the single test that guards rule 2 would be
/// the failure the spec's closing section describes, one layer up: the guard
/// still green, the thing it guards quietly gone.
@Suite struct SecretContainmentTests {
    static let paneID = "8B0E6B1E-6C1B-4C56-9E5E-2C1E9F3A7D40"

    /// The vocabulary a capability field would be named in. Deliberately wider
    /// than the words this codebase uses, because the field that breaks the rule
    /// will be named by whoever adds it and not by whoever wrote this list.
    static let capabilityVocabulary = [
        "token",
        "secret",
        "credential",
        "capability",
        "rendezvous",
        "ticket",
        "auth",
        "bearer",
        "nonce",
        "password",
        "passphrase",
        "key",
    ]

    /// The only field allowed to match that vocabulary, spelled as
    /// `Type.property`, and the only one this suite will ever allow without the
    /// spec being amended first.
    static let boundedException = "ControlResult.rendezvous"

    /// Its wire spelling, checked separately because a `CodingKeys` rename would
    /// change what crosses the socket without touching the property name.
    static let boundedExceptionWireKey = "result.rendezvous"

    // MARK: The sample

    /// Every response shape with every field populated.
    ///
    /// Population is not cosmetic: the reflection walk can only descend into a
    /// nested value that exists, and ``theSampleFillsEveryFieldOfEveryShape``
    /// fails when a newly added field is left out of this, so the two tests hold
    /// each other up.
    static let record = PaneRecord(
        pane: paneID,
        window: 1,
        tab: 2,
        workingDirectory: "/Users/x/Projects/vault",
        anchor: "/Users/x/Projects",
        branch: "control-channel",
        activity: "running",
        attention: "needsInput",
        createdBy: paneID,
        channels: ["reviewer"],
        peers: [paneID]
    )

    static let result = ControlResult(
        pane: paneID,
        name: "reviewer",
        rendezvous: "an-admission-ticket",
        zoomed: true,
        panes: [record],
        messages: [ControlMessage(from: paneID, text: "a body")],
        more: true,
        dropped: 3
    )

    static let error = ControlError(code: .refused, message: "why it failed")

    static let response = ControlResponse(ok: true, result: result, error: error)

    /// The types the walk is expected to reach. Hand-written, and then checked
    /// against what the walk actually found, so a nested shape added without
    /// being listed here fails rather than going unexamined.
    static let expectedShapes: Set<String> = [
        "ControlResponse",
        "ControlResult",
        "PaneRecord",
        "ControlMessage",
        "ControlError",
    ]

    // MARK: Reflection

    struct Field {
        let path: String
        let label: String
        let type: String
    }

    /// Every declared property of every shape the response can reach, by
    /// reflection rather than by a list, because a list is exactly what a new
    /// field gets left out of.
    static func walk(
        _ value: Any,
        typeName: String,
        fields: inout [Field],
        shapes: inout Set<String>,
        depth: Int = 0
    ) {
        guard depth < 8 else { return }
        let mirror = Mirror(reflecting: value)
        guard mirror.children.isEmpty == false else { return }

        if mirror.displayStyle == .collection {
            for child in mirror.children {
                let element = unwrap(child.value)
                walk(
                    element,
                    typeName: "\(type(of: element))",
                    fields: &fields,
                    shapes: &shapes,
                    depth: depth + 1
                )
            }
            return
        }

        shapes.insert(typeName)
        for child in mirror.children {
            guard let label = child.label else { continue }
            fields.append(Field(
                path: "\(typeName).\(label)",
                label: label,
                type: "\(type(of: child.value))"
            ))
            let unwrapped = unwrap(child.value)
            walk(
                unwrapped,
                typeName: "\(type(of: unwrapped))",
                fields: &fields,
                shapes: &shapes,
                depth: depth + 1
            )
        }
    }

    /// Peels `Optional` so the walk descends into a populated field rather than
    /// stopping at the box around it.
    static func unwrap(_ value: Any) -> Any {
        var current = value
        while Mirror(reflecting: current).displayStyle == .optional {
            guard let inner = Mirror(reflecting: current).children.first?.value else { break }
            current = inner
        }
        return current
    }

    static func surface() -> (fields: [Field], shapes: Set<String>) {
        var fields: [Field] = []
        var shapes: Set<String> = []
        walk(response, typeName: "ControlResponse", fields: &fields, shapes: &shapes)
        return (fields, shapes)
    }

    // MARK: The invariant

    @Test func noResponseFieldIsNamedLikeACapabilityExceptTheOneBoundedException() {
        let (fields, shapes) = Self.surface()
        #expect(fields.isEmpty == false, "the reflection walk found nothing to check")
        #expect(shapes == Self.expectedShapes, "a response shape was added without being listed")

        var allowed: [String] = []
        for field in fields {
            let lowered = field.label.lowercased()
            guard Self.capabilityVocabulary.contains(where: { lowered.contains($0) }) else {
                continue
            }
            if field.path == Self.boundedException {
                allowed.append(field.path)
                continue
            }
            let reason = "\(field.path) is named like a capability. The wire carries display ids, "
                + "which session.json already holds, and exactly one ticket, which is "
                + "\(Self.boundedException). Adding a second exception is a spec change."
            Issue.record("\(reason)")
        }

        // Present, used once, and at that exact path. This is what makes a
        // rename fail: move the ticket to a field called anything else and this
        // list comes back empty.
        #expect(
            allowed == [Self.boundedException],
            "the one bounded exception is no longer where the spec says it is"
        )
    }

    /// The type check, which has no exception at all. ``PaneSecret`` is not
    /// `Encodable`, so a field of that type would not compile into a response;
    /// this asserts the same thing one level up, where a future `Codable` on the
    /// declaration would otherwise quietly make it possible.
    @Test func noResponseFieldIsTypedAsACapability() {
        let (fields, _) = Self.surface()
        for field in fields {
            for capability in ["PaneSecret", "RendezvousToken", "EdgeSecret"] {
                #expect(
                    field.type.contains(capability) == false,
                    "\(field.path) carries a \(capability)"
                )
            }
        }
    }

    /// A capability cannot be encoded at all, which is a stronger guarantee than
    /// any field-by-field check: it is the compiler refusing rather than a test
    /// noticing.
    ///
    /// Stated as an assertion anyway so that adding the conformance has to be
    /// somebody's deliberate act with a red test in front of them, rather than an
    /// autocompleted `Codable` on a declaration line.
    ///
    /// All three of them. The pane capability is the one rule 2 is written about;
    /// the rendezvous ticket reaches the wire as a plain `String` in the one
    /// bounded exception and must not acquire a second, quieter route; and the
    /// per-edge secret is never returned by any verb at all.
    @Test func aCapabilityIsNotEncodableInTheFirstPlace() {
        for capability in [PaneSecret.self as Any.Type, RendezvousToken.self, EdgeSecret.self] {
            #expect(capability is Encodable.Type == false)
            #expect(capability is Decodable.Type == false)
        }
    }

    /// A capability that reached a log line would be as leaked as one that
    /// reached a response body, and the only difference is that nobody would be
    /// looking for it there. So it redacts itself in both string conversions.
    @Test func aCapabilityRedactsItselfWhenPrinted() {
        let live = "a-live-capability"
        let values: [(any CustomStringConvertible, String)] = [
            (PaneSecret(live), live),
            (RendezvousToken(live), live),
            (EdgeSecret(live), live),
        ]
        for (value, raw) in values {
            #expect("\(value)".contains(raw) == false)
            #expect(String(reflecting: value).contains(raw) == false)
        }
        #expect(PaneSecret(live).rawValue == live)
        #expect(RendezvousToken(live).rawValue == live)
        #expect(EdgeSecret(live).rawValue == live)
    }

    // MARK: The wire, as opposed to the declarations

    /// The same rule applied to the encoded frame, because a `CodingKeys` rename
    /// would change what crosses the socket without touching a property name, and
    /// the reflection walk above would not see it.
    @Test func noWireKeyOfAResponseIsNamedLikeACapabilityExceptTheOneException() {
        guard let line = ControlWire.encodeResponse(Self.response),
              let object = try? JSONSerialization.jsonObject(with: line)
        else {
            Issue.record("the populated response did not encode")
            return
        }

        var keys: [String] = []
        Self.collectKeys(object, prefix: "", into: &keys)
        #expect(keys.isEmpty == false)

        var allowed: [String] = []
        for key in keys {
            let leaf = key.split(separator: ".").last.map(String.init) ?? key
            let lowered = leaf.lowercased()
            guard Self.capabilityVocabulary.contains(where: { lowered.contains($0) }) else {
                continue
            }
            if key == Self.boundedExceptionWireKey {
                allowed.append(key)
                continue
            }
            Issue.record("the wire key \(key) is named like a capability")
        }
        #expect(allowed == [Self.boundedExceptionWireKey])
    }

    static func collectKeys(_ node: Any, prefix: String, into keys: inout [String]) {
        if let object = node as? [String: Any] {
            for (key, value) in object {
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                keys.append(path)
                collectKeys(value, prefix: path, into: &keys)
            }
        } else if let array = node as? [Any] {
            for element in array {
                collectKeys(element, prefix: prefix, into: &keys)
            }
        }
    }

    /// Every declared field of every shape reaches the wire in the sample above.
    ///
    /// Without this, a field added to a response and forgotten here would be nil,
    /// omitted from the encoded frame, skipped by the reflection walk's descent,
    /// and silently unexamined by the very test written to examine it.
    @Test func theSampleFillsEveryFieldOfEveryShape() {
        assertFullyPopulated(Self.response, "ControlResponse")
        assertFullyPopulated(Self.result, "ControlResult")
        assertFullyPopulated(Self.record, "PaneRecord")
        assertFullyPopulated(ControlMessage(from: Self.paneID, text: "a body"), "ControlMessage")
        assertFullyPopulated(Self.error, "ControlError")
    }

    func assertFullyPopulated(_ value: some Encodable, _ name: String) {
        let declared = Set(Mirror(reflecting: value).children.compactMap(\.label))
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            Issue.record("\(name) did not encode to an object")
            return
        }
        #expect(
            declared == Set(object.keys),
            "\(name) declares \(declared.sorted()) and the sample encodes \(object.keys.sorted())"
        )
    }
}
