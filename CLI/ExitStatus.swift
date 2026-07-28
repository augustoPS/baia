import Foundation
import PaneControl

/// What the process exits with, so a script can branch without reading prose.
///
/// The reason ``ControlErrorCode`` is a closed enum is that a caller programs
/// against the code and not against the message, and a caller invoking the CLI
/// rather than the socket programs against the exit status instead. So every
/// code gets its own number, and the numbers are not reused for anything the CLI
/// decides on its own.
///
/// The four local statuses sit below ten and the wire codes start at ten, which
/// keeps "the CLI could not even ask" distinguishable from "baia answered no"
/// without a second stream to consult.
enum ExitStatus {
    /// The request was answered `ok`.
    static let ok: Int32 = 0

    /// The arguments did not name a command this build has, or named one with
    /// arguments it cannot take. Nothing was sent.
    static let usage: Int32 = 1

    /// This shell is not a baia pane, or is a pane of an instance running
    /// without a channel. Nothing was sent.
    static let environment: Int32 = 2

    /// The socket refused, died mid-exchange, or answered something this build
    /// cannot read.
    static let transport: Int32 = 3

    /// The status for one wire error code.
    ///
    /// **No `default:`, and it must never get one.** A new ``ControlErrorCode``
    /// has to be given a status here before the CLI compiles, which is the same
    /// mechanism `ControlVerb.scope` uses. A fallthrough would silently give a
    /// new failure the number of an old one, and every script branching on it
    /// would be wrong in a way no test looks at.
    static func status(for code: ControlErrorCode) -> Int32 {
        switch code {
        case .badVersion:
            10
        case .badFrame:
            11
        case .unknownVerb:
            12
        case .badToken:
            13
        case .unauthorized:
            14
        case .disabled:
            15
        case .notFound:
            16
        case .refused:
            17
        case .internal:
            18
        }
    }

    /// One row per code, for `--help`.
    ///
    /// Generated from ``ControlErrorCode/allCases`` and ``status(for:)`` rather
    /// than written out, so the documented mapping cannot drift from the one the
    /// process exits with. A hand-maintained table in the help text is a claim
    /// nothing checks, and this CLI has no test target to check it with.
    static var documentedMapping: [(status: Int32, name: String, blurb: String)] {
        ControlErrorCode.allCases.map { code in
            (status(for: code), code.rawValue, blurb(for: code))
        }
    }

    /// What the code means in one clause. Exhaustive for the same reason.
    private static func blurb(for code: ControlErrorCode) -> String {
        switch code {
        case .badVersion:
            "this helper was copied out of a different build of baia"
        case .badFrame:
            "the frame was not one complete request, or was over the cap"
        case .unknownVerb:
            "baia has no verb by that name"
        case .badToken:
            "the pane secret in the environment is not a registered one"
        case .unauthorized:
            "the target is outside this pane's scope"
        case .disabled:
            "the channel, or this verb's own settings key, is off"
        case .notFound:
            "the named thing does not exist"
        case .refused:
            "understood and allowed, and the workspace said no"
        case .internal:
            "a failure on baia's side"
        }
    }
}
