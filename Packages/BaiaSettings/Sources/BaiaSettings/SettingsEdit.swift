import Foundation

/// Every key `~/.config/baia/config.json` carries, in the order the file writes
/// them.
///
/// One list rather than three: ``SettingsDecoder/knownKeys`` is pinned equal to
/// it by a test, ``SettingsWriter/keyOrder`` is derived from it, and
/// ``SettingsCategory`` places every active member of it. A key added here and
/// forgotten anywhere else fails a test rather than dropping out of a write.
public enum SettingsKey: String, CaseIterable, Sendable, Hashable {
    case fontFamily
    case fontSize
    case themeName
    case backgroundHex
    case backgroundOpacity
    case backgroundBlur
    case windowPadding
    case windowPaddingBalance
    case transparentTitlebar
    case optionAsAlt
    case cursorStyle
    case projectRoots
    case discoveryMaxDepth
    case notificationsEnabled
    case gitPollSeconds
    case activityPollSeconds
    case restoreSession
    case focusAccent
    case attentionStyle
    case attentionAccent
    case alertBehavior
    case chromeStyle
    case sidebar
    case controlChannelEnabled
    case controlAllowRun
    case controlAllowRead

    /// Whether the key drives a supported behavior that Settings can expose.
    ///
    /// `backgroundBlur` remains readable, writable, and emitted for Ghostty
    /// configuration compatibility, but the supported material paths keep the
    /// window compositor blur off. `transparentTitlebar` also stays file
    /// compatible and is read by nothing. Settings does not show either key.
    public var isActive: Bool {
        self != .backgroundBlur && self != .transparentTitlebar
    }
}

/// Why an edit cannot be written, in words a control can show beside itself.
public struct SettingsValidationError: Error, Equatable, Sendable {
    public let key: SettingsKey
    public let message: String

    public init(key: SettingsKey, message: String) {
        self.key = key
        self.message = message
    }
}

/// One field's new value, typed per key.
///
/// A control proposes one of these, ``SettingsTransactionController`` validates
/// it, and ``SettingsWriter`` patches exactly this key into the document. The
/// value carried is what the control holds, not what the file spells:
/// ``validated()`` is where the file's canonical forms are produced, so a hex
/// typed as `#ABC` is written as `#aabbcc` and a project root chosen as an
/// absolute path under the home directory is written with a tilde.
public enum SettingsEdit: Equatable, Sendable {
    case fontFamily(String?)
    case fontSize(Double)
    case themeName(String)
    case backgroundHex(String)
    case backgroundOpacity(Double)
    case backgroundBlur(Bool)
    case windowPadding(Double)
    case windowPaddingBalance(Bool)
    case transparentTitlebar(Bool)
    case optionAsAlt(Bool)
    case cursorStyle(CursorStyle)
    case projectRoots([String])
    case discoveryMaxDepth(Int)
    case notificationsEnabled(Bool)
    case gitPollSeconds(Double)
    case activityPollSeconds(Double)
    case restoreSession(Bool)
    case focusAccent(FocusAccent)
    case attentionStyle(AttentionStyle)
    case attentionAccent(AttentionAccent)
    case alertBehavior(AlertBehavior)
    case chromeStyle(ChromeStyle)
    case sidebar(SidebarContent)
    case controlChannelEnabled(Bool)
    case controlAllowRun(Bool)
    case controlAllowRead(Bool)

    public var key: SettingsKey {
        switch self {
        case .fontFamily: .fontFamily
        case .fontSize: .fontSize
        case .themeName: .themeName
        case .backgroundHex: .backgroundHex
        case .backgroundOpacity: .backgroundOpacity
        case .backgroundBlur: .backgroundBlur
        case .windowPadding: .windowPadding
        case .windowPaddingBalance: .windowPaddingBalance
        case .transparentTitlebar: .transparentTitlebar
        case .optionAsAlt: .optionAsAlt
        case .cursorStyle: .cursorStyle
        case .projectRoots: .projectRoots
        case .discoveryMaxDepth: .discoveryMaxDepth
        case .notificationsEnabled: .notificationsEnabled
        case .gitPollSeconds: .gitPollSeconds
        case .activityPollSeconds: .activityPollSeconds
        case .restoreSession: .restoreSession
        case .focusAccent: .focusAccent
        case .attentionStyle: .attentionStyle
        case .attentionAccent: .attentionAccent
        case .alertBehavior: .alertBehavior
        case .chromeStyle: .chromeStyle
        case .sidebar: .sidebar
        case .controlChannelEnabled: .controlChannelEnabled
        case .controlAllowRun: .controlAllowRun
        case .controlAllowRead: .controlAllowRead
        }
    }

    /// The value `settings` currently holds for `key`, as an edit.
    ///
    /// This is what an undo writes back. `projectRoots` comes out expanded,
    /// because that is what ``Settings`` holds; ``jsonValue`` abbreviates it
    /// again on the way to the file, so the round trip keeps the tilde.
    public static func value(of key: SettingsKey, in settings: Settings) -> SettingsEdit {
        switch key {
        case .fontFamily: .fontFamily(settings.fontFamily)
        case .fontSize: .fontSize(settings.fontSize)
        case .themeName: .themeName(settings.themeName)
        case .backgroundHex: .backgroundHex(settings.backgroundHex)
        case .backgroundOpacity: .backgroundOpacity(settings.backgroundOpacity)
        case .backgroundBlur: .backgroundBlur(settings.backgroundBlur)
        case .windowPadding: .windowPadding(settings.windowPadding)
        case .windowPaddingBalance: .windowPaddingBalance(settings.windowPaddingBalance)
        case .transparentTitlebar: .transparentTitlebar(settings.transparentTitlebar)
        case .optionAsAlt: .optionAsAlt(settings.optionAsAlt)
        case .cursorStyle: .cursorStyle(settings.cursorStyle)
        case .projectRoots: .projectRoots(settings.projectRoots)
        case .discoveryMaxDepth: .discoveryMaxDepth(settings.discoveryMaxDepth)
        case .notificationsEnabled: .notificationsEnabled(settings.notificationsEnabled)
        case .gitPollSeconds: .gitPollSeconds(settings.gitPollSeconds)
        case .activityPollSeconds: .activityPollSeconds(settings.activityPollSeconds)
        case .restoreSession: .restoreSession(settings.restoreSession)
        case .focusAccent: .focusAccent(settings.focusAccent)
        case .attentionStyle: .attentionStyle(settings.attentionStyle)
        case .attentionAccent: .attentionAccent(settings.attentionAccent)
        case .alertBehavior: .alertBehavior(settings.alertBehavior)
        case .chromeStyle: .chromeStyle(settings.chromeStyle)
        case .sidebar: .sidebar(settings.sidebar)
        case .controlChannelEnabled: .controlChannelEnabled(settings.controlChannelEnabled)
        case .controlAllowRun: .controlAllowRun(settings.controlAllowRun)
        case .controlAllowRead: .controlAllowRead(settings.controlAllowRead)
        }
    }

    /// The edit in the file's canonical form, or why it cannot be written.
    ///
    /// The rules are the decoder's: every range is a ``Settings/Limits`` bound,
    /// every enum is already typed, and the hex grammar is the one
    /// `SettingsDecoder` accepts. An edit that passes here decodes back without
    /// landing in `invalidKeys`, which a test pins for every key.
    public func validated() -> Result<SettingsEdit, SettingsValidationError> {
        switch self {
        case let .fontFamily(family):
            // An empty name means "the terminal's own font", which the file
            // spells as null. Whitespace is trimmed so a stray space cannot name
            // a font nobody has.
            let trimmed = family?.trimmingCharacters(in: .whitespaces) ?? ""
            return .success(.fontFamily(trimmed.isEmpty ? nil : trimmed))

        case let .fontSize(size):
            guard size.isFinite, Settings.Limits.fontSize.contains(size) else {
                return .failure(Self.error(.fontSize, "Font size must be between 4 and 72 points."))
            }
            return .success(self)

        case let .themeName(name):
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .failure(Self.error(.themeName, "Choose a theme."))
            }
            return .success(self)

        case let .backgroundHex(hex):
            guard let canonical = Self.canonicalHex(hex) else {
                return .failure(Self.error(
                    .backgroundHex,
                    "Use a colour like #141414 or #abc."
                ))
            }
            return .success(.backgroundHex(canonical))

        case let .backgroundOpacity(opacity):
            guard opacity.isFinite, Settings.Limits.opacity.contains(opacity) else {
                return .failure(Self.error(.backgroundOpacity, "Opacity must be between 0% and 100%."))
            }
            return .success(self)

        case let .windowPadding(padding):
            guard padding.isFinite, Settings.Limits.padding.contains(padding) else {
                return .failure(Self.error(.windowPadding, "Padding must be between 0 and 128 points."))
            }
            return .success(self)

        case let .projectRoots(roots):
            let trimmed = roots.map { $0.trimmingCharacters(in: .whitespaces) }
            guard trimmed.allSatisfy({ !$0.isEmpty }) else {
                return .failure(Self.error(.projectRoots, "Every project root needs a path."))
            }
            return .success(.projectRoots(trimmed))

        case let .discoveryMaxDepth(depth):
            guard Settings.Limits.discoveryDepth.contains(Double(depth)) else {
                return .failure(Self.error(.discoveryMaxDepth, "Discovery depth must be between 1 and 8."))
            }
            return .success(self)

        case let .gitPollSeconds(seconds):
            guard seconds.isFinite, Settings.Limits.pollSeconds.contains(seconds) else {
                return .failure(Self.error(.gitPollSeconds, Self.pollMessage))
            }
            return .success(self)

        case let .activityPollSeconds(seconds):
            guard seconds.isFinite, Settings.Limits.pollSeconds.contains(seconds) else {
                return .failure(Self.error(.activityPollSeconds, Self.pollMessage))
            }
            return .success(self)

        case .backgroundBlur, .windowPaddingBalance, .transparentTitlebar, .optionAsAlt,
             .cursorStyle, .notificationsEnabled, .restoreSession, .focusAccent,
             .attentionStyle, .attentionAccent, .alertBehavior, .chromeStyle, .sidebar,
             .controlChannelEnabled, .controlAllowRun, .controlAllowRead:
            return .success(self)
        }
    }

    private static let pollMessage = "Polling must be between 0.25 and 3600 seconds."

    private static func error(_ key: SettingsKey, _ message: String) -> SettingsValidationError {
        SettingsValidationError(key: key, message: message)
    }

    /// `#rrggbb`, lowercase, or nil for anything the decoder would reject.
    ///
    /// The three-digit shorthand is expanded rather than kept, so the file holds
    /// one spelling per colour and two edits of the same colour serialize to the
    /// same bytes. Full-width digits are refused for the decoder's reason: they
    /// satisfy `isHexDigit` and ghostty cannot parse them.
    static func canonicalHex(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let digits = trimmed.dropFirst()
        guard digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        switch digits.count {
        case 6:
            return "#" + digits.lowercased()
        case 3:
            return "#" + digits.map { String(repeating: $0, count: 2) }.joined().lowercased()
        default:
            return nil
        }
    }

    /// Moves this field on `settings`, expanding a project root's tilde the way
    /// the decoder does so the running value never starts at a literal `~`.
    func apply(to settings: inout Settings) {
        switch self {
        case let .fontFamily(value): settings.fontFamily = value
        case let .fontSize(value): settings.fontSize = value
        case let .themeName(value): settings.themeName = value
        case let .backgroundHex(value): settings.backgroundHex = value
        case let .backgroundOpacity(value): settings.backgroundOpacity = value
        case let .backgroundBlur(value): settings.backgroundBlur = value
        case let .windowPadding(value): settings.windowPadding = value
        case let .windowPaddingBalance(value): settings.windowPaddingBalance = value
        case let .transparentTitlebar(value): settings.transparentTitlebar = value
        case let .optionAsAlt(value): settings.optionAsAlt = value
        case let .cursorStyle(value): settings.cursorStyle = value
        case let .projectRoots(value): settings.projectRoots = value.map(Settings.expandingTilde)
        case let .discoveryMaxDepth(value): settings.discoveryMaxDepth = value
        case let .notificationsEnabled(value): settings.notificationsEnabled = value
        case let .gitPollSeconds(value): settings.gitPollSeconds = value
        case let .activityPollSeconds(value): settings.activityPollSeconds = value
        case let .restoreSession(value): settings.restoreSession = value
        case let .focusAccent(value): settings.focusAccent = value
        case let .attentionStyle(value): settings.attentionStyle = value
        case let .attentionAccent(value): settings.attentionAccent = value
        case let .alertBehavior(value): settings.alertBehavior = value
        case let .chromeStyle(value): settings.chromeStyle = value
        case let .sidebar(value): settings.sidebar = value
        case let .controlChannelEnabled(value): settings.controlChannelEnabled = value
        case let .controlAllowRun(value): settings.controlAllowRun = value
        case let .controlAllowRead(value): settings.controlAllowRead = value
        }
    }

    /// The member the file carries for this edit.
    ///
    /// `fontFamily` is null rather than absent, matching the default file, so the
    /// key stays visible to whoever opens the file looking for the spelling.
    /// Project roots below the home directory are written with a tilde: the file
    /// is meant to be copied between machines and the decoder expands it on read.
    var jsonValue: JSONValue {
        switch self {
        case let .fontFamily(value): value.map { JSONValue.string($0) } ?? .null
        case let .fontSize(value): .number(value)
        case let .themeName(value): .string(value)
        case let .backgroundHex(value): .string(value)
        case let .backgroundOpacity(value): .number(value)
        case let .backgroundBlur(value): .bool(value)
        case let .windowPadding(value): .number(value)
        case let .windowPaddingBalance(value): .bool(value)
        case let .transparentTitlebar(value): .bool(value)
        case let .optionAsAlt(value): .bool(value)
        case let .cursorStyle(value): .string(value.rawValue)
        case let .projectRoots(value): .array(value.map { .string(Settings.abbreviatingTilde($0)) })
        case let .discoveryMaxDepth(value): .number(Double(value))
        case let .notificationsEnabled(value): .bool(value)
        case let .gitPollSeconds(value): .number(value)
        case let .activityPollSeconds(value): .number(value)
        case let .restoreSession(value): .bool(value)
        case let .focusAccent(value): .string(value.rawValue)
        case let .attentionStyle(value): .string(value.rawValue)
        case let .attentionAccent(value): .string(value.rawValue)
        case let .alertBehavior(value): .string(value.rawValue)
        case let .chromeStyle(value): .string(value.rawValue)
        case let .sidebar(value): .string(value.rawValue)
        case let .controlChannelEnabled(value): .bool(value)
        case let .controlAllowRun(value): .bool(value)
        case let .controlAllowRead(value): .bool(value)
        }
    }
}

public extension Settings {
    /// A copy with `edit` applied, in the edit's canonical form.
    ///
    /// What the running value becomes when the file accepts the edit, without
    /// the file: the app's self-check reads it, and it is the same `apply(to:)`
    /// the transaction controller uses, so the two cannot disagree.
    func applying(_ edit: SettingsEdit) -> Settings {
        var next = self
        switch edit.validated() {
        case let .success(valid): valid.apply(to: &next)
        case .failure: break
        }
        return next
    }
}

extension Settings {
    /// The inverse of ``expandingTilde(_:)``: a path below the home directory
    /// spelled with a leading `~`, and any other path unchanged.
    static func abbreviatingTilde(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
